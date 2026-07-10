import Foundation
import WebKit

/// Reply-capable transport for the Rust diff sidecar. Each request is a bounded
/// stdin/stdout exchange with a short-lived child process. The sidecar never
/// opens a socket, and WebKit never receives filesystem paths or process access.
@MainActor
final class DiffSidecarBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxDiff"
    static let shared = DiffSidecarBridge()

    nonisolated private enum InvocationCompletion: Sendable {
        case terminated(Int32)
        case timedOut
        case missingTermination
        case cancelled
    }

    nonisolated private enum InvocationError: Error {
        case timedOut
        case missingTermination
    }

    private static var handlerInstalledKey: UInt8 = 0
    private static let maximumRequestBytes = 1024 * 1024
    private nonisolated static let maximumResponseBytes = 32 * 1024 * 1024
    // Longer than the sidecar's 120-second branch regeneration limit.
    private nonisolated static let requestTimeout: TimeInterval = 130

    static func installIfNeeded(on userContentController: WKUserContentController) {
        guard objc_getAssociatedObject(userContentController, &handlerInstalledKey) == nil else {
            return
        }
        userContentController.addScriptMessageHandler(
            shared,
            contentWorld: .page,
            name: handlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &handlerInstalledKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    static func installViewerBridges(on userContentController: WKUserContentController) {
        DiffCommentsBridge.installIfNeeded(on: userContentController)
        installIfNeeded(on: userContentController)
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard DiffCommentsBridge.isTrustedDiffViewerFrame(message.frameInfo),
              JSONSerialization.isValidJSONObject(message.body),
              let request = try? JSONSerialization.data(withJSONObject: message.body),
              request.count <= Self.maximumRequestBytes else {
            replyHandler(Self.failureResponse(body: message.body, code: "notAllowed", message: "Diff sidecar request was rejected"), nil)
            return
        }

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                do {
                    return Result<Data, Error>.success(try await Self.runSidecar(request: request))
                } catch {
                    return Result<Data, Error>.failure(error)
                }
            }.value
            switch result {
            case .success(let responseData):
                guard let response = try? JSONSerialization.jsonObject(with: responseData) else {
                    replyHandler(Self.failureResponse(body: message.body, code: "invalidResponse", message: "Diff sidecar returned invalid JSON"), nil)
                    return
                }
                replyHandler(response, nil)
            case .failure:
                replyHandler(Self.failureResponse(body: message.body, code: "sidecarUnavailable", message: "Diff sidecar is unavailable"), nil)
            }
        }
    }

    nonisolated private static func runSidecar(request: Data) async throws -> Data {
        let resources = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let sidecar = resources.appendingPathComponent("cmux-diff-sidecar", isDirectory: false)
        let cmux = resources.appendingPathComponent("cmux", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: sidecar.path),
              FileManager.default.isExecutableFile(atPath: cmux.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        let process = Process()
        process.executableURL = sidecar
        process.arguments = ["rpc", "--root", root.path, "--cmux", cmux.path]
        process.standardError = FileHandle.nullDevice

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output

        let termination = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        do {
            try input.fileHandleForWriting.write(contentsOf: request)
            try input.fileHandleForWriting.close()
        } catch {
            process.terminate()
            throw error
        }

        let outputTask = Task.detached(priority: .userInitiated) {
            output.fileHandleForReading.readDataToEndOfFile()
        }

        let completion = await withTaskGroup(of: InvocationCompletion.self) { group in
            group.addTask {
                for await status in termination {
                    return .terminated(status)
                }
                return Task.isCancelled ? .cancelled : .missingTermination
            }
            group.addTask {
                do {
                    try await ContinuousClock().sleep(for: .seconds(requestTimeout))
                    return .timedOut
                } catch {
                    return .cancelled
                }
            }
            guard let completion = await group.next() else {
                return InvocationCompletion.missingTermination
            }
            if case .timedOut = completion {
                if process.isRunning {
                    process.terminate()
                }
            }
            group.cancelAll()
            return completion
        }
        if case .cancelled = completion {
            if process.isRunning {
                process.terminate()
            }
        }
        let outputData = await outputTask.value

        let status: Int32
        switch completion {
        case .terminated(let terminationStatus):
            status = terminationStatus
        case .timedOut:
            throw InvocationError.timedOut
        case .missingTermination:
            throw InvocationError.missingTermination
        case .cancelled:
            throw CancellationError()
        }

        guard status == 0,
              !outputData.isEmpty,
              outputData.count <= maximumResponseBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return outputData
    }

    private static func failureResponse(body: Any, code: String, message: String) -> [String: Any] {
        let request = body as? [String: Any]
        return [
            "id": request?["id"] as? String ?? "unknown",
            "version": request?["version"] as? Int ?? 1,
            "result": NSNull(),
            "error": ["code": code, "message": message],
        ]
    }
}
