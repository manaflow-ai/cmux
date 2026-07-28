import Foundation
import CmuxTerminal
import AppKit
import CmuxRemoteSession
import UniformTypeIdentifiers

enum TerminalImageTransferMode {
    case paste
    case drop
}

nonisolated enum TerminalRemoteUploadTarget: Equatable, Sendable {
    case workspaceRemote
    case detectedSSH(DetectedSSHSession)
}

nonisolated enum TerminalImageTransferTarget: Equatable, Sendable {
    case local
    case remote(TerminalRemoteUploadTarget)
    /// The terminal may be running an unmanaged remote shell, but cmux has no
    /// structured upload route for it.
    case unknown
}

enum TerminalImageTransferPlan: Equatable {
    case insertText(String)
    case insertTextSegments([String], interSegmentDelay: TimeInterval)
    case uploadFiles([URL], TerminalRemoteUploadTarget)
    case reject
}

enum TerminalImageTransferPreparedContent: Equatable {
    case insertText(String)
    case fileURLs([URL])
    case reject
}

enum PasteboardFileURLReader {
    static let legacyFilenamesPboardType = NSPasteboard.PasteboardType(rawValue: "NSFilenamesPboardType")
    static let fileURLPasteboardTypes: Set<NSPasteboard.PasteboardType> = [
        .fileURL,
        legacyFilenamesPboardType
    ]

    static func hasFileURLType(_ pasteboardTypes: [NSPasteboard.PasteboardType]) -> Bool {
        return pasteboardTypes.contains { fileURLPasteboardTypes.contains($0) }
    }

    static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        var fileURLs: [URL] = []

        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        for object in objects {
            if let url = object as? URL, url.isFileURL {
                fileURLs.append(url.standardizedFileURL)
            }
        }

        if let paths = pasteboard.propertyList(forType: legacyFilenamesPboardType) as? [String] {
            fileURLs.append(
                contentsOf: paths
                    .filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: $0).standardizedFileURL }
            )
        }

        if let rawFileURL = pasteboard.string(forType: .fileURL),
           let url = URL(string: rawFileURL),
           url.isFileURL {
            fileURLs.append(url.standardizedFileURL)
        }

        var seen: Set<String> = []
        return fileURLs.filter { url in
            seen.insert(url.path).inserted
        }
    }
}

enum TerminalImageTransferExecutionError: LocalizedError {
    case cancelled
    case unverifiedRemoteSession

    var errorDescription: String? {
        switch self {
        case .cancelled:
            return nil
        case .unverifiedRemoteSession:
            return String(
                localized: "terminal.fileTransfer.error.unverifiedRemoteSession",
                defaultValue: "cmux can't determine where this terminal is running. Exit the manually started remote shell, or open the host through a cmux-managed SSH workspace, then try again."
            )
        }
    }
}

@MainActor
enum TerminalImageTransferGuidance {
    static func presentUnverifiedRemoteSession(in window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(
            localized: "terminal.fileTransfer.error.unverifiedRemoteSession.title",
            defaultValue: "File transfer target unavailable"
        )
        alert.informativeText =
            TerminalImageTransferExecutionError.unverifiedRemoteSession
                .localizedDescription
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// The app-side conformer of the session coordinator's transfer-cancellation
// seam; the operation already provided every member by contract, the
// extension only names the cancellation error the legacy controller threw
// directly.
extension TerminalImageTransferOperation: RemoteTransferCancelling {
    var cancellationError: any Error {
        TerminalImageTransferExecutionError.cancelled
    }
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
            target: target,
            mode: mode
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
            return plan(preparedContent: preparedContent, target: .local, mode: mode)
        case .fileURLs:
            return plan(preparedContent: preparedContent, target: resolveTarget(), mode: mode)
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
        target: TerminalImageTransferTarget,
        mode: TerminalImageTransferMode = .paste
    ) -> TerminalImageTransferPlan {
        switch preparedContent {
        case .insertText(let text):
            return .insertText(text)
        case .fileURLs(let fileURLs):
            return plan(fileURLs: fileURLs, target: target, mode: mode)
        case .reject:
            return .reject
        }
    }

    static func plan(
        fileURLs: [URL],
        target: TerminalImageTransferTarget,
        mode: TerminalImageTransferMode = .paste
    ) -> TerminalImageTransferPlan {
        guard !fileURLs.isEmpty else { return .reject }

        switch target {
        case .local:
            if mode == .drop,
               fileURLs.count > 1,
               fileURLs.allSatisfy(isLocalImageFileURL) {
                return .insertTextSegments(
                    insertedTextSegments(forFileURLs: fileURLs),
                    interSegmentDelay: 2.0
                )
            }
            return .insertText(insertedText(forFileURLs: fileURLs))
        case .remote(let remoteTarget):
            guard fileURLs.allSatisfy(isRemoteUploadableFileURL) else {
                return .insertText(insertedText(forFileURLs: fileURLs))
            }
            return .uploadFiles(fileURLs, remoteTarget)
        case .unknown:
            return .reject
        }
    }

    @discardableResult
    static func executeForTesting(
        plan: TerminalImageTransferPlan,
        operation: TerminalImageTransferOperation? = nil,
        uploadWorkspaceRemote: ([URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        uploadDetectedSSH: (DetectedSSHSession, [URL], TerminalImageTransferOperation, @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Void,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        onFailure: @escaping (Error) -> Void
    ) -> TerminalImageTransferOperation? {
        execute(
            plan: plan,
            operation: operation,
            uploadWorkspaceRemote: uploadWorkspaceRemote,
            uploadDetectedSSH: uploadDetectedSSH,
            insertText: insertText,
            scheduleAfter: scheduleAfter,
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
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        },
        onFailure: @escaping (Error) -> Void
    ) -> TerminalImageTransferOperation? {
        switch plan {
        case .insertText(let text):
            if let operation, !operation.finish() {
                return operation
            }
            insertText(text)
            return operation
        case .insertTextSegments(let segments, let interSegmentDelay):
            let operation = operation ?? TerminalImageTransferOperation()
            sendTextSegments(
                segments,
                index: 0,
                interSegmentDelay: interSegmentDelay,
                operation: operation,
                insertText: insertText,
                scheduleAfter: scheduleAfter
            )
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
        value.terminalShellEscaped
    }

    static func insertedText(forPathStrings paths: [String]) -> String {
        paths
            .map(escapeForShell)
            .joined(separator: " ")
    }

    static func insertedText(forFileURLs fileURLs: [URL]) -> String {
        insertedText(forPathStrings: fileURLs.map(\.path))
    }

    private static func insertedTextSegments(forFileURLs fileURLs: [URL]) -> [String] {
        fileURLs
            .map(\.path)
            .map(escapeForShell)
            .enumerated()
            .map { index, text in
                index == 0 ? text : " " + text
            }
    }

    private static func isLocalImageFileURL(_ fileURL: URL) -> Bool {
        let normalizedFileURL = fileURL.standardizedFileURL
        guard normalizedFileURL.isFileURL,
              let resourceValues = try? normalizedFileURL.resourceValues(forKeys: [.isRegularFileKey]),
              resourceValues.isRegularFile == true else {
            return false
        }

        let pathExtension = normalizedFileURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pathExtension.isEmpty,
              let type = UTType(filenameExtension: pathExtension),
              type.conforms(to: .image) else {
            return false
        }
        return true
    }

    private static func isRemoteUploadableFileURL(_ fileURL: URL) -> Bool {
        let normalizedFileURL = fileURL.standardizedFileURL
        guard normalizedFileURL.isFileURL,
              let resourceValues = try? normalizedFileURL.resourceValues(forKeys: [.isRegularFileKey]),
              resourceValues.isRegularFile == true else {
            return false
        }
        return true
    }

    private static func preparePaste(
        pasteboard: NSPasteboard
    ) -> TerminalImageTransferPreparedContent {
        let fileURLs = fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return .fileURLs(fileURLs)
        }

        if let string = GhosttyApp.terminalPasteboard.stringContents(from: pasteboard), !string.isEmpty {
            return .insertText(string)
        }

        switch GhosttyApp.terminalPasteboard.materializeImageFileURLIfNeeded(from: pasteboard) {
        case .saved(let imageURL):
            return .fileURLs([imageURL])
        case .rejectedImagePayload:
            return .reject
        case .noDecodableImagePayload:
            break
        }

        // Clipboard managers can advertise unusable image types alongside valid text.
        if let string = GhosttyApp.terminalPasteboard.fallbackPlainTextContents(from: pasteboard), !string.isEmpty {
            return .insertText(string)
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
        return GhosttyApp.terminalPasteboard.saveImageFileURLsIfNeeded(from: pasteboard, assumeNoText: true)
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
        PasteboardFileURLReader.fileURLs(from: pasteboard)
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

    private static func sendTextSegments(
        _ segments: [String],
        index: Int,
        interSegmentDelay: TimeInterval,
        operation: TerminalImageTransferOperation,
        insertText: @escaping (String) -> Void,
        scheduleAfter: @escaping (TimeInterval, @escaping () -> Void) -> Void
    ) {
        guard !operation.isCancelled else { return }
        guard index < segments.count else {
            _ = operation.finish()
            return
        }

        let segment = segments[index]
        if !segment.isEmpty {
            insertText(segment)
        }

        let nextIndex = index + 1
        guard nextIndex < segments.count else {
            _ = operation.finish()
            return
        }

        scheduleAfter(interSegmentDelay) {
            sendTextSegments(
                segments,
                index: nextIndex,
                interSegmentDelay: interSegmentDelay,
                operation: operation,
                insertText: insertText,
                scheduleAfter: scheduleAfter
            )
        }
    }
}

extension TerminalSurface {
    /// Captures the host that owns this terminal from cmux-managed state.
    ///
    /// File transfers must not infer an upload destination from the foreground
    /// process command line. A manually started `ssh` process does not transfer
    /// ownership of caller-supplied files to that host.
    @MainActor
    func managedImageTransferTargetSnapshot() -> TerminalImageTransferTarget {
        guard let workspace = owningWorkspace() else {
            return .unknown
        }
        if workspace.isRemoteTerminalSurface(id) {
            return .remote(.workspaceRemote)
        }
        if let remoteTmuxTarget = AppDelegate.shared?.remoteTmuxController
            .remoteUploadTarget(forSurfaceId: id) {
            return .remote(remoteTmuxTarget)
        }
        // Foreground-process inspection is only a conservative hazard signal.
        // It never supplies credentials or an upload destination. A manually
        // started remote shell stays unknown until a structured cmux route
        // owns it.
        if let ttyName = workspace.surfaceTTYNames[id],
           TerminalSSHSessionDetector.hasForegroundRemoteShell(forTTY: ttyName) {
            return .unknown
        }
        return .local
    }

    @MainActor
    func resolvedImageTransferTarget() -> TerminalImageTransferTarget {
        managedImageTransferTargetSnapshot()
    }
}
