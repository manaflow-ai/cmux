import CmuxNextAgentPane
import Foundation

/// Files the person drops or pastes into a chat on this Mac that the composer can't attach as a
/// prompt block (a binary, a text file over the inline limit): any file attaches (Lawrence
/// 2026-10-20). The page sends their bytes (``AgentPaneUpload``, the same `chat.upload` call a
/// Cloud chat's upload uses), and only for a chat whose folder is on this Mac, with a real gesture
/// in its pane, the app writes them owner-only under `~/Library/Application Support/cmux/Chat
/// Uploads/<random>/<index>/<name>` and answers where each is, so the composer puts the paths in
/// the prompt and the agent opens them with its own tools.
@MainActor
struct AgentChatUploads {
    /// The folder every local chat upload goes under.
    nonisolated static var root: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appending(path: "cmux", directoryHint: .isDirectory)
            .appending(path: "Chat Uploads", directoryHint: .isDirectory)
    }

    /// The upload for chat tab `tab`, nil unless its folder is on this Mac (`isLocal`).
    static func uploader(tab: String, services: AppServices) -> AgentPaneUploader? {
        guard services.agentTabs.gitLink?(tab)?.isLocal == true, let root else { return nil }
        return { files in
            let folder = root.appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
            do {
                let paths = try await Task.detached { try write(files, in: folder) }.value
                let uploads = zip(files, paths).map { file, path -> [String: Any] in ["name": file.name, "path": path] }
                return AgentPaneReply.success(["uploads": uploads])
            } catch {
                return AgentPaneReply.failure(code: "upload_failed", message: AgentChatUploadStrings.failed)
            }
        }
    }

    /// Writes each file owner-only to `folder/<index>/<name>` (its own folder, so two files may share
    /// a name), with every folder owner-only too; the paths, in order.
    nonisolated static func write(_ files: [AgentPaneUpload], in folder: URL) throws -> [String] {
        let manager = FileManager.default, owner: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try manager.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: owner)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false, attributes: owner)
        return try files.enumerated().map { index, file in
            let parent = folder.appending(path: String(index), directoryHint: .isDirectory)
            try manager.createDirectory(at: parent, withIntermediateDirectories: false, attributes: owner)
            let url = parent.appending(path: file.name, directoryHint: .notDirectory)
            guard manager.createFile(atPath: url.path, contents: file.data, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            return url.path
        }
    }
}

/// A local chat upload's failure text, shown in the composer. Keys live in Resources/Cloud.xcstrings
/// beside the Cloud chat upload's.
enum AgentChatUploadStrings {
    static var failed: String {
        String(localized: "chat.upload.localFailed", defaultValue: "Couldn't save the file on this Mac.", table: "Cloud", bundle: .module)
    }
}
