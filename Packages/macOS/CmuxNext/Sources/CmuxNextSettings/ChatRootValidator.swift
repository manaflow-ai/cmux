public import Foundation

/// Refuses chat roots before accessing protected folders. Keep the guarded lists in sync with
/// cmux-tui/crates/acpmux/src/protected_folders.rs. No folder contents are ever read.
public nonisolated struct ChatRootValidator: Sendable {
    public let home: String
    private let homes: [String]
    private let readLink: @Sendable (String) -> String?

    /// Inject a home and a readlink-only resolver to validate without touching a user's files.
    public init(home: String = NSHomeDirectory(), readLink: @escaping @Sendable (String) -> String? = {
        try? FileManager.default.destinationOfSymbolicLink(atPath: $0)
    }) {
        self.home = home
        self.readLink = readLink
        homes = [home, Self.resolveHome(home, readLink: readLink)]
    }

    /// A localized refusal, or nil for an absolute, unprotected path.
    public func refusal(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.contains("\0") else {
            return SettingsText.keyed("settings.chats.root.relative", "Use an absolute folder path.").text
        }
        // Check the spelling before even readlink: resolving a protected descendant would read it.
        if let reason = guarded(path, final: true) { return reason }
        var parts = path.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !parts.isEmpty {
            let part = parts.removeFirst()
            if part == "." { continue }
            if part == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            if let reason = guarded(candidate, final: parts.isEmpty) { return reason }
            if let target = readLink(candidate) {
                links += 1
                guard links <= 40 else {
                    return SettingsText.keyed("settings.chats.root.symlink", "This folder has too many symbolic links.").text
                }
                if target.hasPrefix("/") { resolved = [] }
                parts = target.split(separator: "/").map(String.init) + parts
            } else {
                resolved.append(part)
            }
        }
        return guarded("/" + resolved.joined(separator: "/"), final: true)
    }

    private func guarded(_ path: String, final: Bool) -> String? {
        let folded = path.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let homes = homes.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        if final && folded.isEmpty {
            return SettingsText.keyed("settings.chats.root.system", "The root folder cannot be a chat folder.").text
        }
        if final && homes.contains(folded) {
            return SettingsText.keyed("settings.chats.root.home", "Choose a harness data folder, not your home folder.").text
        }
        func under(_ root: String) -> Bool { folded == root || folded.hasPrefix(root + "/") }
        if ["volumes", "network", "net"].contains(where: under) {
            return SettingsText.keyed("settings.chats.root.volume", "Folders on other or network volumes are not allowed.").text
        }
        let guarded = ["Desktop", "Documents", "Downloads", "Pictures", "Music", "Movies",
                       "Library/Mobile Documents", "Library/CloudStorage", "Library/Containers",
                       "Library/Group Containers", "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars"]
        if homes.contains(where: { home in guarded.contains { under(home + "/" + $0.lowercased()) } }) {
            return SettingsText.keyed("settings.chats.root.protected", "This folder is protected by macOS privacy controls.").text
        }
        return nil
    }

    /// Only resolves the home path itself, never a child of a protected folder.
    private static func resolveHome(_ home: String, readLink: (String) -> String?) -> String {
        var parts = home.split(separator: "/").map(String.init)
        var resolved: [String] = []
        var links = 0
        while !parts.isEmpty {
            let part = parts.removeFirst()
            if part == "." { continue }
            if part == ".." { if !resolved.isEmpty { resolved.removeLast() }; continue }
            let candidate = "/" + (resolved + [part]).joined(separator: "/")
            if let target = readLink(candidate) {
                links += 1
                guard links <= 40 else { return home }
                if target.hasPrefix("/") { resolved = [] }
                parts = target.split(separator: "/").map(String.init) + parts
            } else { resolved.append(part) }
        }
        return "/" + resolved.joined(separator: "/")
    }

}
