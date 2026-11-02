public import Foundation

/// Where this Mac keeps the files a chat's composer could not attach as prompt blocks (the App's
/// `AgentChatUploads`) and a chat's long dictation recordings: `Chat Uploads/sessions/<session>/
/// <upload>/...` under `~/Library/Application Support/cmux`, or `<upload>/...` at the top for a chat
/// with no session yet or not on this Mac. An upload folder is a UUID; the App's launch sweep
/// removes it after 30 days, and a chat's folder goes when this Mac's acpmux deletes the chat.
public nonisolated struct ChatUploadFolders: Sendable, Equatable {
    /// The folder every chat upload goes under.
    public let root: URL
    /// The folder under ``root`` that holds a folder per chat (session ids are UUIDs, as upload
    /// folders' names are, so they never share one folder).
    public static let sessions = "sessions"

    public init(root: URL) {
        self.root = root
    }

    /// The folders in this user's Application Support; nil without one.
    public static var standard: ChatUploadFolders? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first.map {
            ChatUploadFolders(root: $0.appending(path: "cmux", directoryHint: .isDirectory)
                .appending(path: "Chat Uploads", directoryHint: .isDirectory))
        }
    }

    /// Chat `session`'s folder.
    public func chat(_ session: String) -> URL {
        root.appending(path: Self.sessions, directoryHint: .isDirectory).appending(path: session, directoryHint: .isDirectory)
    }

    /// A fresh upload folder (not made yet): in chat `session`'s folder, else at the top.
    public func freshUpload(session: String?) -> URL {
        (session.flatMap { Self.isSessionName($0) ? chat($0) : nil } ?? root)
            .appending(path: UUID().uuidString.lowercased(), directoryHint: .isDirectory)
    }

    /// Whether acpmux session id `id` names one folder: letters, digits, `-` and `_` only.
    public static func isSessionName(_ id: String) -> Bool {
        !id.isEmpty && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Whether `name` is an upload folder's: a UUID.
    public static func isUploadName(_ name: String) -> Bool {
        UUID(uuidString: name) != nil
    }
}
