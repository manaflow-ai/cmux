import Foundation

/// A kept tab to restart a shell in (`end-terminals-keep-layout-v1`, wire
/// `relaunch`): the workspace store's keep-layout record, with the
/// directory the tab's shell was in when Quit's End Sessions, Keep Layout
/// ended it.
public struct TabRelaunch: Sendable, Hashable, Codable {
    public var cwd: String?
    /// Parked (`park-tabs`, `tab-park-v1`): its shell starts when its
    /// workspace is first shown, not when the app connects.
    public var onShow: Bool

    public init(cwd: String?, onShow: Bool = false) {
        self.cwd = cwd
        self.onShow = onShow
    }

    /// Whether the tab's shell waits until its workspace is shown: parked (``onShow``), or its
    /// folder is privacy-protected (LAUNCH-NO-TCC-PROMPTS). A new shell in ~/Downloads reads it
    /// at once, and macOS asks in cmux's name; a kept tab never does that at launch.
    /// - Parameter home: the home folder the protected folders are in; nil: this user's.
    public func startsOnShow(home: String? = nil) -> Bool {
        onShow || cwd.map { inProtectedFolder($0, home: home ?? NSHomeDirectory()) } == true
    }

    enum CodingKeys: String, CodingKey {
        case cwd
        case onShow = "on_show"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        onShow = try container.decodeIfPresent(Bool.self, forKey: .onShow) ?? false
    }
}

/// Whether `path` is in a folder of the protected-folder list (`ProtectedFolderEntry`), by its
/// spelling only: resolving it would read inside the folder. Case-insensitive, as the volume is.
private func inProtectedFolder(_ path: String, home: String) -> Bool {
    let spelled = path == "~" || path.hasPrefix("~/") ? home + path.dropFirst() : path
    let folded = spelled.lowercased()
    func under(_ root: String) -> Bool {
        var root = root.lowercased()
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return folded == root || folded.hasPrefix(root + "/")
    }
    let homeRoot = home.hasSuffix("/") ? String(home.dropLast()) : home
    return ProtectedFolderEntry.roots.contains { under($0.path) }
        || ProtectedFolderEntry.inHome.contains { under(homeRoot + "/" + $0.path) }
}
