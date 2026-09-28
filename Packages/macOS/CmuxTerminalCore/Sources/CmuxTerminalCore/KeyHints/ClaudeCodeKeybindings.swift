public import Foundation

/// The user's Claude Code keybindings from `~/.claude/keybindings.json`,
/// indexed by action id.
///
/// The file lists contexts, each mapping chords to action ids, where `null`
/// unbinds a default:
///
/// ```json
/// {"bindings": [{"context": "Chat", "bindings": {"ctrl+e": "chat:externalEditor", "ctrl+u": null}}]}
/// ```
///
/// Chords are normalized to named keys (`ctrl+o`, `shift+tab`, `escape`);
/// a chord sequence (`ctrl+x ctrl+k`) becomes several keys. Bindings that
/// can't be sent to a terminal (`cmd+k`) are dropped.
public struct ClaudeCodeKeybindings: Sendable, Equatable {
    /// Key sequences bound to each action id, sorted for a stable choice.
    public var keysByAction: [String: [[String]]]

    public static let empty = ClaudeCodeKeybindings(keysByAction: [:])

    public init(keysByAction: [String: [[String]]]) {
        self.keysByAction = keysByAction
    }

    /// Parses the file's contents. Anything unreadable yields no bindings.
    public init(data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let contexts = root["bindings"] as? [[String: Any]] else {
            self = .empty
            return
        }
        var keysByAction: [String: [[String]]] = [:]
        for context in contexts {
            guard let bindings = context["bindings"] as? [String: Any] else { continue }
            for (chord, value) in bindings {
                guard let action = value as? String, let keys = Self.keys(forChord: chord) else { continue }
                if !(keysByAction[action]?.contains(keys) ?? false) {
                    keysByAction[action, default: []].append(keys)
                }
            }
        }
        for action in keysByAction.keys {
            keysByAction[action]?.sort { $0.joined(separator: " ") < $1.joined(separator: " ") }
        }
        self.keysByAction = keysByAction
    }

    private static func keys(forChord chord: String) -> [String]? {
        let parts = chord.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !parts.isEmpty else { return nil }
        var keys: [String] = []
        for part in parts {
            guard let key = AgentKeyHintDetector.chord(part) else { return nil }
            keys.append(key)
        }
        return keys
    }
}

/// Reads `~/.claude/keybindings.json` and caches it by modification date,
/// so repeated clicks re-read the file only after it changes.
///
/// A click checks the file each time (``current()``). Hover passes a
/// `maxAge` so moving the pointer across cells stats the file at most once
/// per `maxAge`.
public final class ClaudeCodeKeybindingsFile: @unchecked Sendable {
    public static let shared = ClaudeCodeKeybindingsFile(
        url: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
            .appendingPathComponent("keybindings.json", isDirectory: false)
    )

    private let url: URL
    private let now: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var checkedAt: TimeInterval?
    private var cachedModificationDate: Date?
    private var cachedSize: Int?
    private var cached: ClaudeCodeKeybindings = .empty

    /// - Parameters:
    ///   - url: The keybindings file.
    ///   - now: A monotonic clock in seconds, for `maxAge`.
    public init(
        url: URL,
        now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.url = url
        self.now = now
    }

    /// The current bindings, or none when the file is missing or invalid.
    ///
    /// - Parameter maxAge: Seconds a previous check stays good for; the file
    ///   is not stat'ed again until they pass. `0` always checks.
    public func current(maxAge: TimeInterval = 0) -> ClaudeCodeKeybindings {
        let time = now()
        lock.lock()
        if let checkedAt, maxAge > 0, time - checkedAt < maxAge {
            defer { lock.unlock() }
            return cached
        }
        lock.unlock()
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        let size = (attributes?[.size] as? NSNumber)?.intValue
        lock.lock()
        defer { lock.unlock() }
        checkedAt = time
        guard modificationDate != cachedModificationDate || size != cachedSize else { return cached }
        cachedModificationDate = modificationDate
        cachedSize = size
        cached = attributes == nil ? .empty : (try? Data(contentsOf: url)).map(ClaudeCodeKeybindings.init(data:)) ?? .empty
        return cached
    }
}
