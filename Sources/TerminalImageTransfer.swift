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

enum TerminalImageTransferPlanner {
    private static let shellEscapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

    static func plan(
        pasteboard: NSPasteboard,
        mode: TerminalImageTransferMode,
        target: TerminalImageTransferTarget
    ) -> TerminalImageTransferPlan {
        switch mode {
        case .paste:
            return planPaste(pasteboard: pasteboard, target: target)
        case .drop:
            return planDrop(pasteboard: pasteboard, target: target)
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

    static func executeForTesting(
        plan: TerminalImageTransferPlan,
        uploadWorkspaceRemote: ([URL], @escaping (Result<[String], Error>) -> Void) -> Void,
        uploadDetectedSSH: (DetectedSSHSession, [URL], @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) {
        execute(
            plan: plan,
            uploadWorkspaceRemote: uploadWorkspaceRemote,
            uploadDetectedSSH: uploadDetectedSSH,
            insertText: insertText,
            onFailure: onFailure
        )
    }

    static func execute(
        plan: TerminalImageTransferPlan,
        uploadWorkspaceRemote: ([URL], @escaping (Result<[String], Error>) -> Void) -> Void,
        uploadDetectedSSH: (DetectedSSHSession, [URL], @escaping (Result<[String], Error>) -> Void) -> Void,
        insertText: @escaping (String) -> Void,
        onFailure: @escaping () -> Void
    ) {
        switch plan {
        case .insertText(let text):
            insertText(text)
        case .uploadFiles(let fileURLs, .workspaceRemote):
            uploadWorkspaceRemote(fileURLs) { result in
                finishUpload(result: result, insertText: insertText, onFailure: onFailure)
            }
        case .uploadFiles(let fileURLs, .detectedSSH(let session)):
            uploadDetectedSSH(session, fileURLs) { result in
                finishUpload(result: result, insertText: insertText, onFailure: onFailure)
            }
        case .reject:
            onFailure()
        }
    }

    static func escapeForShell(_ value: String) -> String {
        var result = value
        for char in shellEscapeCharacters {
            result = result.replacingOccurrences(of: String(char), with: "\\\(char)")
        }
        return result
    }

    private static func planPaste(
        pasteboard: NSPasteboard,
        target: TerminalImageTransferTarget
    ) -> TerminalImageTransferPlan {
        let fileURLs = fileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return plan(fileURLs: fileURLs, target: target)
        }

        if let string = GhosttyPasteboardHelper.stringContents(from: pasteboard), !string.isEmpty {
            return .insertText(string)
        }

        if let imageURL = GhosttyPasteboardHelper.saveImageFileURLIfNeeded(from: pasteboard, assumeNoText: true) {
            return plan(fileURLs: [imageURL], target: target)
        }

        if let rawURL = pasteboard.string(forType: .URL), !rawURL.isEmpty {
            return .insertText(escapeForShell(rawURL))
        }

        return .reject
    }

    private static func planDrop(
        pasteboard: NSPasteboard,
        target: TerminalImageTransferTarget
    ) -> TerminalImageTransferPlan {
        let fileURLs = materializedFileURLs(from: pasteboard)
        if !fileURLs.isEmpty {
            return plan(fileURLs: fileURLs, target: target)
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
        onFailure: @escaping () -> Void
    ) {
        switch result {
        case .success(let remotePaths):
            let content = remotePaths
                .map(escapeForShell)
                .joined(separator: " ")
            guard !content.isEmpty else {
                onFailure()
                return
            }
            insertText(content)
        case .failure:
            onFailure()
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
