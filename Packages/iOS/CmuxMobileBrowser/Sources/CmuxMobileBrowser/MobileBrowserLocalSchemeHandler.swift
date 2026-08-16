#if canImport(UIKit)
import CMUXMobileCore
import Foundation
import WebKit

/// Errors produced while fetching a bounded local browser resource.
enum MobileBrowserLocalTransferError: Swift.Error {
    case invalidURL
    case malformedChunk
    case resourceTooLarge
    case pageTooLarge
    case unavailable
}

/// Streams Mac file resources into WebKit without copying a dependency tree to
/// the phone's filesystem.
@MainActor
final class MobileBrowserLocalSchemeHandler: NSObject, WKURLSchemeHandler {
    private typealias ActiveTask = (webTask: WKURLSchemeTask, operation: Task<Void, Never>)

    private let panelID: String
    private let loader: MobileBrowserLocalResourceLoader
    private let policy: MobileBrowserLocalResourcePolicy
    private let onFetchStarted: @MainActor () -> Void
    private let onFetchProgress: @MainActor (Double) -> Void
    private let onFetchFinished: @MainActor () -> Void
    private let onFetchFailed: @MainActor (Swift.Error) -> Void
    private var activeTasks: [ObjectIdentifier: ActiveTask] = [:]
    private var activeFetchCount = 0
    private var activeFetchFailure: Swift.Error?
    private var pageGeneration = 0
    private var pageBytesServed: Int64 = 0

    init(
        panelID: String,
        loader: MobileBrowserLocalResourceLoader,
        policy: MobileBrowserLocalResourcePolicy = MobileBrowserLocalResourcePolicy(),
        onFetchStarted: @escaping @MainActor () -> Void,
        onFetchProgress: @escaping @MainActor (Double) -> Void,
        onFetchFinished: @escaping @MainActor () -> Void,
        onFetchFailed: @escaping @MainActor (Swift.Error) -> Void
    ) {
        self.panelID = panelID
        self.loader = loader
        self.policy = policy
        self.onFetchStarted = onFetchStarted
        self.onFetchProgress = onFetchProgress
        self.onFetchFinished = onFetchFinished
        self.onFetchFailed = onFetchFailed
        super.init()
    }

    /// Starts a fresh aggregate budget for a top-level local page navigation.
    func beginPageLoad() {
        pageGeneration &+= 1
        for task in activeTasks.values {
            task.operation.cancel()
        }
        activeTasks.removeAll()
        activeFetchCount = 0
        activeFetchFailure = nil
        pageBytesServed = 0
    }

    /// Cancels all in-flight WebKit resource requests during view teardown.
    func cancelAll() {
        pageGeneration &+= 1
        let tasks = activeTasks.values
        activeTasks.removeAll()
        for task in tasks {
            task.operation.cancel()
        }
        activeFetchCount = 0
        activeFetchFailure = nil
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let generation = pageGeneration
        let operation = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.serve(urlSchemeTask, taskID: taskID, generation: generation)
        }
        activeTasks[taskID] = (urlSchemeTask, operation)
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        activeTasks.removeValue(forKey: taskID)?.operation.cancel()
    }

    private func serve(
        _ webTask: WKURLSchemeTask,
        taskID: ObjectIdentifier,
        generation: Int
    ) async {
        defer { activeTasks[taskID] = nil }
        guard generation == pageGeneration else { return }
        guard let requestURL = webTask.request.url,
              let components = MobileBrowserLocalURL.components(from: requestURL),
              components.panelID.caseInsensitiveCompare(panelID) == .orderedSame else {
            let error = MobileBrowserLocalTransferError.invalidURL
            fail(webTask, error: error)
            onFetchFailed(error)
            return
        }

        activeFetchCount += 1
        if activeFetchCount == 1 {
            onFetchStarted()
        }
        var completed = false
        defer {
            if generation == pageGeneration {
                activeFetchCount = max(0, activeFetchCount - 1)
                if activeFetchCount == 0 {
                    if let failure = activeFetchFailure {
                        activeFetchFailure = nil
                        onFetchFailed(failure)
                    } else if completed {
                        onFetchFinished()
                    }
                }
            }
        }
        do {
            var offset: Int64 = 0
            var responseSent = false
            var totalSize: Int64?
            var mimeType: String?
            while true {
                try Task.checkCancellation()
                guard generation == pageGeneration else { return }
                let chunk = try await loader.fetch(
                    panelID: panelID,
                    path: components.path,
                    offset: offset,
                    length: policy.maximumChunkBytes
                )
                guard chunk.path == components.path,
                      chunk.offset == offset,
                      chunk.totalSize >= 0,
                      chunk.totalSize <= policy.maximumResourceBytes,
                      chunk.data.count <= policy.maximumChunkBytes,
                      totalSize == nil || totalSize == chunk.totalSize else {
                    throw MobileBrowserLocalTransferError.malformedChunk
                }
                totalSize = chunk.totalSize
                mimeType = mimeType ?? chunk.mimeType
                guard generation == pageGeneration else { return }
                let nextPageBytes = pageBytesServed + Int64(chunk.data.count)
                guard nextPageBytes <= policy.maximumPageBytes else {
                    throw MobileBrowserLocalTransferError.pageTooLarge
                }
                pageBytesServed = nextPageBytes

                if !responseSent {
                    let response = HTTPURLResponse(
                        url: requestURL,
                        statusCode: 200,
                        httpVersion: "HTTP/1.1",
                        headerFields: [
                            "Cache-Control": "no-store",
                            "Content-Length": String(chunk.totalSize),
                            "Content-Type": mimeType ?? "application/octet-stream",
                        ]
                    ) ?? URLResponse(
                        url: requestURL,
                        mimeType: mimeType ?? "application/octet-stream",
                        expectedContentLength: Int(chunk.totalSize),
                        textEncodingName: mimeType?.hasPrefix("text/") == true ? "utf-8" : nil
                    )
                    webTask.didReceive(response)
                    responseSent = true
                }
                if !chunk.data.isEmpty {
                    webTask.didReceive(chunk.data)
                }
                let progress = chunk.totalSize == 0
                    ? 1
                    : min(1, Double(offset + Int64(chunk.data.count)) / Double(chunk.totalSize))
                onFetchProgress(progress)
                offset += Int64(chunk.data.count)
                if chunk.eof || offset >= chunk.totalSize {
                    webTask.didFinish()
                    completed = true
                    return
                }
                guard !chunk.data.isEmpty else {
                    throw MobileBrowserLocalTransferError.malformedChunk
                }
            }
        } catch is CancellationError {
            completed = true
            return
        } catch {
            guard generation == pageGeneration else { return }
            activeFetchFailure = error
            fail(webTask, error: error)
        }
    }

    private func fail(_ webTask: WKURLSchemeTask, error: Swift.Error) {
        webTask.didFailWithError(error as NSError)
    }
}
#endif
