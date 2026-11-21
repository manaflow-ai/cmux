import CmuxNextCompat
import Foundation

/// Ghostty's `working-directory`: the folder a new terminal starts in when nothing names one and
/// it inherits none (Ghostty uses it for a window with no focused terminal to inherit from, and for
/// every window when `window-inherit-working-directory = false`). libghostty has no getter for
/// this key (its value is a union without a C form), so this reads the files the loaded config
/// came from (`loadedConfigFiles`, in load order), the way ``GhosttyConfigFontFamily`` does, off the
/// main thread once per config change (`GhosttyRuntime.refreshConfiguredWorkingDirectory`).
///
/// ```swift
/// GhosttyConfigWorkingDirectory.value(configText: "working-directory = ~/fun")?
///     .start(home: NSHomeDirectory(), isDirectory: { _ in true }) // "/Users/me/fun"
/// ```
public nonisolated enum GhosttyConfigWorkingDirectory: Equatable, Sendable {
    /// `home`: the person's home folder.
    case home
    /// `inherit`: the launching process's folder. In cmux the daemon's own default decides.
    case inherit
    /// A path as written: absolute, or `~/` for the home folder.
    case path(String)

    /// The value `paths` set, read in order (a later line wins); nil when none sets it.
    static func value(inFiles paths: [String]) -> Self? {
        var value: Self?
        for path in paths {
            guard let text = try? String(blockingContentsOfFile: path, encoding: .utf8) else { continue }
            value = Self.value(configText: text, after: value)
        }
        return value
    }

    /// `value` after the `working-directory` lines of one config file's `text`. An empty value
    /// resets the key to Ghostty's default (unset), as an empty value does for any Ghostty key.
    static func value(configText text: String, after value: Self? = nil) -> Self? {
        var result = value
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let equals = line.firstIndex(of: "=") else { continue }
            guard line[..<equals].trimmingCharacters(in: .whitespaces) == "working-directory" else { continue }
            var input = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if input.count >= 2, input.hasPrefix("\""), input.hasSuffix("\"") { input = String(input.dropFirst().dropLast()) }
            switch input {
            case "": result = nil
            case "home": result = .home
            case "inherit": result = .inherit
            default: result = .path(input)
            }
        }
        return result
    }

    /// The folder this value names on this Mac: nil for `inherit`, and for a path that is not
    /// absolute (Ghostty requires one) or no longer a folder, so a stale config never makes a
    /// new terminal fail to start.
    func start(home: String, isDirectory: (String) -> Bool) -> String? {
        let folder: String
        switch self {
        case .inherit: return nil
        case .home: folder = home
        case .path(let path):
            folder = path.hasPrefix("~/") ? (home as NSString).appendingPathComponent(String(path.dropFirst(2))) : path
        }
        return folder.hasPrefix("/") && isDirectory(folder) ? folder : nil
    }

    /// Whether `path` is a folder on this Mac.
    static func isFolder(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return FileManager.checked.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }
}
