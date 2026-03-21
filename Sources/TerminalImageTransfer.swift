import Foundation
import AppKit

enum TerminalImageTransferMode {
    case paste
    case drop
}

enum TerminalRemoteUploadTarget: Equatable {
    case workspaceRemote
    case detectedSSH(DetectedSSHSession)
}

enum TerminalImageTransferTarget: Equatable {
    case local
    case remote(TerminalRemoteUploadTarget)
}

enum TerminalImageTransferPlan: Equatable {
    case insertText(String)
    case uploadFiles([URL], TerminalRemoteUploadTarget)
    case reject
}

enum TerminalImageTransferPreparedContent: Equatable {
    case insertText(String)
    case fileURLs([URL])
    case reject
}

enum TerminalImageTransferExecutionError: Error {
    case cancelled
}

final class TerminalImageTransferOperation: @unchecked Sendable {
    private enum State {
        case running
        case cancelled
        case finished
    }

    private let lock = NSLock()
    private var state: State = .running
    private var cancellationHandler: (() -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .cancelled
    }

    func installCancellationHandler(_ handler: @escaping () -> Void) {
        var invokeImmediately = false
        lock.lock()
        switch state {
        case .running:
            cancellationHandler = handler
        case .cancelled:
            invokeImmediately = true
        case .finished:
            break
        }
        lock.unlock()

        if invokeImmediately {
            handler()
        }
    }

    func clearCancellationHandler() {
        lock.lock()
        if state == .running {
            cancellationHandler = nil
        }
        lock.unlock()
    }

    @discardableResult
    func cancel() -> Bool {
        let handler: (() -> Void)?
        lock.lock()
        guard state == .running else {
            lock.unlock()
            return false
        }
        state = .cancelled
        handler = cancellationHandler
        cancellationHandler = nil
        lock.unlock()

        handler?()
        return true
    }

    @discardableResult
    func finish() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .running else { return false }
        state = .finished
        cancellationHandler = nil
        return true
    }

    func throwIfCancelled() throws {
        if isCancelled {
            throw TerminalImageTransferExecutionError.cancelled
        }
    }
}

enum TerminalImageTransferPlanner {
    static func plan(
        pasteboard: NSPasteboard,
        mode: TerminalImageTransferMode,
        target: TerminalImageTransferTarget
    ) -> TerminalImageTransferPlan {
        plan(
            preparedContent: prepare(pasteboard: pasteboard, mode: mode),
            target: target
        )
    }

    static func plan(
        pasteboard: NSPasteboard,
        mode: TerminalImageTransferMode,
        resolveTarget: () -> TerminalImageTransferTarget
    ) -> TerminalImageTransferPlan {
        let preparedContent = prepare(pasteboard: pasteboard, mode: mode)
        switch preparedContent {
        case .insertText, .reject:
            return plan(preparedContent: preparedContent, target: .local)
        case .fileURLs:
            return plan(preparedContent: preparedContent, target: resolveTarget())
        }
    }

    static func prepare(
        pasteboard: NSPasteboard,
        mode: TerminalImageTransferMode
    ) -> TerminalImageTransferPreparedContent {
        switch mode {
        case .paste:
            return preparePaste(pasteboard: pasteboard)
        case .drop:
            return prepareDrop(pasteboard: pasteboard)
        }
    }

    static func plan(
        preparedContent: TerminalImageTransferPreparedContent,
        target: TerminalImageTransferTarget
    ) -> TerminalImageTransferPlan {
        switch preparedContent {
        case .insertText(let text):
            return .insertText(text)
        case .fileURLs(let fileURLs):
            return plan(fileURLs: fileURLs, target: target)
        case .reject:
            return .reject
        }
    }

    static func plan(fileURLs: [URL], target: TerminalImageTransferTarget) -> TerminalImageTransferPlan {
        guard !fileURLs.isEmpty else { return .reject }

        switch target {
        case .local:
            let text = fileURLs
                .map { escapeForShell($0.path) }
                .joined(separator: " ")
            return .insertText(text)
        case .remote(let remoteTarget):
            return .uploadFiles(fileURLs, remoteTarget)
        }
    }

    @discardableResult
    static func executeForTesting(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        uploadWorkspaceRemote: ([URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        uploadDetectedSSH: (DetectedSSHSession, [URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) -> TerminalImageTransferOperation? {
        execute(
            plan: plan,
            operation: operation,
            uploadWorkspaceRemote: uploadWorkspaceRemote,
            uploadDetectedSSH: uploadDetectedSSH,
            insertText: insertText,
            onFailure: onFailure
        )
    }

    @discardableResult
    static func execute(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        uploadWorkspaceRemote: ([URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        uploadDetectedSSH: (DetectedSSHSession, [URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) -> TerminalImageTransferOperation? {
        switch plan {
        case .insertText(let text):
            if let operation, !operation.finish() {
                return operation
            }
            insertText(text)
            return operation
        case .uploadFiles(let fileURLs, .workspaceRemote):
            let operation = operation ?? TerminalImageTransferOperation()
            uploadWorkspaceRemote(fileURLs, operation) { result in
                guard operation.finish() else { return }
                finishUpload(result: result, insertText: insertText, onFailure: onFailure)
            }
            return operation
        case .uploadFiles(let fileURLs, .detectedSSH(let session)):
            let operation = operation ?? TerminalImageTransferOperation()
            uploadDetectedSSH(session, fileURLs, operation) { result in
                guard operation.finish() else { return }
                finishUpload(result: result, insertText: insertText, onFailure: onFailure)
            }
            return operation
        case .reject:
            return operation
        }
    }

    static func escapeForShell(_ value: String) -> String {
        GhosttyPasteboardHelper.escapeForShell(value)
    }

    private static func preparePaste(
        pasteboard: NSPasteboard
    ) -> TerminalImageTransferPreparedContent {
        let fileURLs = fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        if let string = GhosttyPasteboardHelper.stringContents(from: pasteboard), !string.isEmpty {
            return .insertText(string)
        }

        if let imageURL = GhosttyPasteboardHelper.saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: true) {
            return .fileURLs([imageURL])
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(escapeForShell(rawURL))
        }

        return .reject
    }

    private static func prepareDrop(
        pasteboard: NSPasteboard
    ) -> TerminalImageTransferPreparedContent {
        let fileURLs = materializedFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(escapeForShell(rawURL))
        }

        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return .insertText(string)
        }

        return .reject
    }

    private static func materializedFileURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = fileURLs(from: pasteboard)
        if !urls.isEmpty {
            return urls
        }
        if let imageURL = GhosttyPasteboardHelper.saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: true) {
            return [imageURL]
        }
        return []
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] else {
            return []
        }
        return urls.filter(\.isFileURL)
    }

    private static func finishUpload(
        result: Result<[String], Error>,
        insertText: @escaping (String) -> Void,
        onFailure: @escaping (Error) -> Void
    ) {
        switch result {
        case .success(let remotePaths):
            let content = remotePaths
                .map(escapeForShell)
                .joined(separator: " ")
            guard !content.isEmpty else {
                onFailure(NSError(domain: "cmux.remote.drop", code: 5))
                return
            }
            insertText(content)
        case .failure(let error):
            onFailure(error)
        }
    }
}

extension TerminalSurface {
    @MainActor
    func resolvedImageTransferTarget() -> TerminalImageTransferTarget {
        guard let workspace = owningWorkspace() else { return .local }
        if workspace.isRemoteTerminalSurface(id) {
            return .remote(.workspaceRemote)
        }
        if let ttyName = workspace.surfaceTTYNames[id],
           let session = TerminalSSHSessionDetector.detect(forTTY: ttyName) {
            return .remote(.detectedSSH(session))
        }
        return .local
    }
}
