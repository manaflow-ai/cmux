import CmuxNextCompat
public import Foundation

/// A daemon page listener's credential file, `<socket>.websocket.json` (cmux-tui
/// spec/transports.md "App listener and page files"): the endpoint, the page bundle URL and the
/// listener token. Moved out of CmuxNextApp (the Channels page host verb reads it).
public nonisolated struct PageListenerCredentialFile: Decodable, Sendable, Equatable {
    public var pid: Int32
    public var url: String
    public var pages: String
    public var token: String

    /// The file must be this user's, mode 0600, and name a live daemon on loopback: a stale file
    /// (a killed daemon) or one another user planted must never send the token to whatever owns
    /// that port. Nil otherwise.
    public static func read(_ path: String) -> PageListenerCredentialFile? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        guard (attributes?[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes?[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().blockingDecode(PageListenerCredentialFile.self, from: data),
              file.pid > 0, kill(file.pid, 0) == 0,
              file.url.hasPrefix("ws://127.0.0.1:") || file.url.hasPrefix("ws://[::1]:")
        else { return nil }
        return file
    }
}
