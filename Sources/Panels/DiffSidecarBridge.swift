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
    private nonisolated static let processPool = DiffSidecarProcessPool(limit: 4)
    // Longer than the sidecar's 120-second branch regeneration limit.
    private nonisolated static let requestTimeout: TimeInterval = 130
    private var invocations: [UUID: Task<Void, Never>] = [:]
    private var sessionInvocationByViewerToken: [String: UUID] = [:]

    /// Faults the Rust executable and its dynamic dependencies into the OS cache
    /// during app startup. The handshake uses stdio and exits; it never binds a
    /// port or leaves a sidecar process running.
    nonisolated static func prewarm() {
        Task.detached(priority: .utility) {
            let request = Data(#"{"id":"prewarm","version":1,"method":"protocolHandshake"}"#.utf8)
            _ = try? await processPool.run(request: request)
        }
    }

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
        guard Self.isTrustedSidecarFrame(message.frameInfo),
              JSONSerialization.isValidJSONObject(message.body),
              let request = try? JSONSerialization.data(withJSONObject: message.body),
              request.count <= Self.maximumRequestBytes else {
            replyHandler(Self.failureResponse(body: message.body, code: "notAllowed", message: "Diff sidecar request was rejected"), nil)
            return
        }

        let invocationID = UUID()
        let method = (message.body as? [String: Any])?["method"] as? String
        let viewerToken = DiffCommentsBridge.diffViewerToken(from: message.frameInfo.request.url)
        if method == "sessionOpen", let viewerToken,
           let previousID = sessionInvocationByViewerToken[viewerToken] {
            invocations[previousID]?.cancel()
        }

        let task = Task { [weak self] in
            let result: Result<Data, Error>
            do {
                result = .success(try await Self.processPool.run(request: request))
            } catch {
                result = .failure(error)
            }
            guard let self else { return }
            switch result {
            case .success(let responseData):
                guard let response = try? JSONSerialization.jsonObject(with: responseData) else {
                    replyHandler(Self.failureResponse(body: message.body, code: "invalidResponse", message: "Diff sidecar returned invalid JSON"), nil)
                    self.finishInvocation(invocationID, viewerToken: viewerToken)
                    return
                }
                replyHandler(response, nil)
            case .failure:
                replyHandler(Self.failureResponse(body: message.body, code: "sidecarUnavailable", message: "Diff sidecar is unavailable"), nil)
            }
            self.finishInvocation(invocationID, viewerToken: viewerToken)
        }
        invocations[invocationID] = task
        if method == "sessionOpen", let viewerToken {
            sessionInvocationByViewerToken[viewerToken] = invocationID
        }
    }

    private func finishInvocation(_ invocationID: UUID, viewerToken: String?) {
        invocations.removeValue(forKey: invocationID)
        if let viewerToken, sessionInvocationByViewerToken[viewerToken] == invocationID {
            sessionInvocationByViewerToken.removeValue(forKey: viewerToken)
        }
    }

    static func isTrustedSidecarFrame(_ frameInfo: WKFrameInfo) -> Bool {
        frameInfo.isMainFrame && isTrustedSidecarURL(frameInfo.request.url)
    }

    static func isTrustedSidecarURL(_ url: URL?) -> Bool {
        guard let url else { return false }
        return CmuxDiffViewerURLSchemeHandler.shared.allowsNavigation(to: url)
    }

    #if compiler(>=6.2)
    @concurrent
    #else
    @Sendable
    #endif
    nonisolated fileprivate static func runSidecar(request: Data) async throws -> Data {
        let resources = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/bin", isDirectory: true)
        let sidecar = resources.appendingPathComponent("cmux-diff-sidecar", isDirectory: false)
        let cmux = resources.appendingPathComponent("cmux", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: sidecar.path),
              FileManager.default.isExecutableFile(atPath: cmux.path) else {
            throw CocoaError(.fileNoSuchFile)
        }

        let root = try prepareRootDirectory()
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
        return try await withTaskCancellationHandler {
            try process.run()
            do {
                try input.fileHandleForWriting.write(contentsOf: request)
                try input.fileHandleForWriting.close()
            } catch {
                terminate(process: process, input: input, output: output)
                process.waitUntilExit()
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
                group.cancelAll()
                return completion
            }
            switch completion {
            case .timedOut, .cancelled:
                terminate(process: process, input: input, output: output)
                process.waitUntilExit()
            case .terminated, .missingTermination:
                break
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
        } onCancel: {
            terminate(process: process, input: input, output: output)
        }
    }

    nonisolated private static func terminate(process: Process, input: Pipe, output: Pipe) {
        try? input.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
        if process.isRunning {
            process.terminate()
        }
    }

    nonisolated private static func prepareRootDirectory() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("cmux-diff-viewer-\(Darwin.getuid())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        return root
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

actor DiffSidecarProcessPool {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private let limit: Int
    private var activeCount = 0
    private var waiters: [Waiter] = []

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
    }

    func run(request: Data) async throws -> Data {
        try await withPermit {
            try await DiffSidecarBridge.runSidecar(request: request)
        }
    }

    func withPermit<T: Sendable>(
        _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeCount < limit {
            activeCount += 1
            return
        }

        let waiterID = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(waiterID) }
        }
        guard granted else {
            throw CancellationError()
        }
        if Task.isCancelled {
            release()
            throw CancellationError()
        }
    }

    private func cancelWaiter(_ waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: false)
    }

    private func release() {
        if waiters.isEmpty {
            activeCount -= 1
            return
        }
        let waiter = waiters.removeFirst()
        waiter.continuation.resume(returning: true)
    }
}
