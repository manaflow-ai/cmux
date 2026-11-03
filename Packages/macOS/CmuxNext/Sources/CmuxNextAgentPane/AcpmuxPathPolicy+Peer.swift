import Foundation

/// A new chat on another machine (an ssh peer of this Mac's acpmux, `_meta.acpmux.peer`) starts in
/// a folder of that machine: the composer's project picker and the New Tab's location row name
/// one of its folders (webviews App.tsx `chooseProject`, newtab `pickMachine`). That folder need not
/// exist on this Mac, and when a folder of the same name does, it is not the same folder, so the
/// folder rule does not read this Mac's disk or roots for it. The peer's acpmux checks its own
/// folder (an existing directory, its folder trust) when the start reaches it.
nonisolated extension AcpmuxPathPolicy {
    /// The longest folder a start on another machine may name, in UTF-8 bytes (Linux `PATH_MAX`).
    static let peerFolderMaxBytes = 4096

    /// Whether a `session/new`'s `_meta.acpmux` starts the chat on another machine: a non-empty
    /// `peer`, as acpmux reads it (``stampWorkspace(_:id:)`` reads it the same way).
    static func startsOnPeer(_ acpmux: [String: Any]?) -> Bool {
        (acpmux?["peer"] as? String).map { !$0.isEmpty } ?? false
    }

    /// The shape a folder on another machine must have: an absolute path, no NUL, at most
    /// ``peerFolderMaxBytes`` bytes. Its existence is that machine's to check.
    static func isPeerFolder(_ path: String) -> Bool {
        path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= peerFolderMaxBytes
    }
}
