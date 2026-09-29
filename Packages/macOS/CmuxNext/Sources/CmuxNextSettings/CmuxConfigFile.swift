public import Foundation

/// Reads and writes `~/.config/cmux/cmux.json`. An actor so file IO and
/// parsing stay off the main actor and writes are serialized. Writes edit
/// the JSONC source in place (comments and unknown keys survive) and
/// publish atomically; the file watcher then reloads and applies them, so
/// there is one path from disk to live settings.
public actor CmuxConfigFile {
    public nonisolated let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The conventional location: `<home>/.config/cmux/cmux.json`.
    public static func defaultURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appending(path: ".config/cmux/cmux.json")
    }

    public enum Failure: Error, Sendable, CustomStringConvertible {
        case unreadable(String)
        case invalidPath(String)

        public var description: String {
            switch self {
            case .unreadable(let message): "cmux.json is not valid JSONC: \(message)"
            case .invalidPath(let path): "invalid settings path '\(path)'"
            }
        }
    }

    /// The raw source text, or "" when the file does not exist.
    public func source() throws -> String {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch CocoaError.fileReadNoSuchFile {
            return ""
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return ""
        }
    }

    /// The parsed document. A missing file is an empty object.
    public func document() throws -> JSONValue {
        let text = try source()
        do {
            return try JSONC.parse(text)
        } catch {
            throw Failure.unreadable(String(describing: error))
        }
    }

    /// The value at `path`, or nil when absent. An empty path is the root.
    public func value(at path: [String]) throws -> JSONValue? {
        try document().value(at: path)
    }

    /// Sets `path` to `value` and publishes the file atomically.
    public func set(_ value: JSONValue, at path: [String]) throws {
        guard !path.isEmpty else { throw Failure.invalidPath("") }
        let current = try source()
        _ = try validated(current)
        try publish(try JSONC.setting(value, at: path, in: current))
    }

    /// Removes the member at `path`. No-op when absent.
    public func remove(_ path: [String]) throws {
        guard !path.isEmpty else { throw Failure.invalidPath("") }
        let current = try source()
        _ = try validated(current)
        let updated = try JSONC.removing(path, in: current)
        if updated != current { try publish(updated) }
    }

    private func validated(_ text: String) throws -> JSONValue {
        do {
            return try JSONC.parse(text)
        } catch {
            // Never rewrite a file the user left broken: they would lose it.
            throw Failure.unreadable(String(describing: error))
        }
    }

    private func publish(_ text: String) throws {
        // Write through a symlinked cmux.json (dotfile repos) instead of
        // replacing the link with a regular file.
        let url = self.url.resolvingSymlinksInPath()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        try Data(text.utf8).write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    // MARK: - Key paths

    /// Splits a dotted settings path. Action IDs contain dots
    /// (`tabGroup.create`), so everything after `shortcuts.bindings.`,
    /// `shortcuts.when.`, or a direct `shortcuts.` action key is one key.
    /// Callers that need other dotted keys pass an array path instead.
    public static func keyPath(from dotted: String) -> [String] {
        let trimmed = dotted.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        for prefix in ["shortcuts.bindings.", "shortcuts.when."] where trimmed.hasPrefix(prefix) {
            let rest = String(trimmed.dropFirst(prefix.count))
            return prefix.split(separator: ".").map(String.init) + (rest.isEmpty ? [] : [rest])
        }
        if trimmed.hasPrefix("shortcuts.") {
            let rest = String(trimmed.dropFirst("shortcuts.".count))
            let head = rest.split(separator: ".", maxSplits: 1).first.map(String.init) ?? rest
            if CmuxConfigSnapshot.reservedShortcutKeys.contains(head) {
                return ["shortcuts"] + rest.split(separator: ".").map(String.init)
            }
            return ["shortcuts", rest]
        }
        return trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    }
}
