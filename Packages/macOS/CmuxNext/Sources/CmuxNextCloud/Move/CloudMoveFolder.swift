import Foundation

/// The folder a chat moves with: the git working copy that holds the chat's
/// folder (`cmux link sync push` copies only a working copy's top folder), or
/// the chat's folder itself outside git.
public nonisolated struct CloudMoveFolder: Sendable, Equatable {
    /// The folder that is synced, absolute, on this Mac.
    public let root: String
    /// The chat's folder inside ``root``; empty for ``root`` itself.
    public let subpath: String

    /// Nil for a relative folder, or one whose `..` parts climb above the disk's root.
    ///
    /// - Parameter folder: The chat's folder, absolute, on this Mac.
    public init?(chat folder: String) {
        guard let start = Self.normalized(folder) else { return nil }
        // The folder and each folder above it, up to the disk's root ("/" is its own parent).
        let folders = sequence(first: start) { folder in
            let parent = (folder as NSString).deletingLastPathComponent
            return parent == folder || parent.isEmpty ? nil : parent
        }
        let top = folders.first { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(".git")) } ?? start
        // `top` is `start` or a folder above it, so the chat's folder never escapes the synced one.
        guard start == top || start.hasPrefix(top == "/" ? "/" : top + "/") else { return nil }
        root = top
        subpath = String(start.dropFirst(top.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// `path` with its `.` and `..` parts resolved and no trailing slash, as written otherwise:
    /// standardizing would also turn /private/tmp into /tmp, a path the chat never reported.
    ///
    /// - Parameter path: An absolute path.
    /// - Returns: The resolved path, or nil for a relative path or one that climbs above the root.
    public static func normalized(_ path: String) -> String? {
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if parts.popLast() == nil { return nil }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The home folder or the disk's root: never copied to a machine.
    public var isTooBroad: Bool {
        let path = URL(fileURLWithPath: root).standardizedFileURL.path
        return path == "/" || path == URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
    }

    /// The folder's name on a machine: its own name and a short hash of where it
    /// is on this Mac, so two folders with one name never share a synced folder.
    public var remoteName: String {
        var hash: UInt32 = 0x811c_9dc5
        for byte in root.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        let name = URL(fileURLWithPath: root).lastPathComponent
        return (name.isEmpty || name == "/" ? "folder" : name) + "-" + String(format: "%06x", hash & 0xff_ffff)
    }

    /// The synced folder under `workRoot` on the machine, and the chat's folder there.
    ///
    /// - Parameter workRoot: The machine's folder for synced folders.
    /// - Returns: The synced folder and the chat's folder in it, both on the machine.
    public func remote(under workRoot: String) -> (folder: String, chat: String) {
        let folder = workRoot.hasSuffix("/") ? workRoot + remoteName : workRoot + "/" + remoteName
        return (folder, subpath.isEmpty ? folder : folder + "/" + subpath)
    }
}
