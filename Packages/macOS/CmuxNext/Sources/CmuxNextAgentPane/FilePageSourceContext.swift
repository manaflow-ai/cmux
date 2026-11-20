import CmuxNextPages
public import CmuxNextSettings
public import Foundation

/// Native-only provenance of a local file open. The Markdown page never chooses a socket,
/// session or tab. Navigating to another file does not transfer this capability to it.
@MainActor
public final class FilePageSourceContext {
    public let id = UUID().uuidString
    private let file: URL
    private let readUses: (String?) async throws -> JSONValue
    private let isCurrent: () -> Bool
    private let revealReply: (String, Int) -> Bool
    private struct Reply: Hashable { let turn: String; let reply: String }
    private var shown: [Reply: Int] = [:]

    /// Explicit dependencies keep the authority boundary testable without a running app or daemon.
    public init(file: URL, read: @escaping (String?) async throws -> JSONValue,
                current: @escaping () -> Bool, reveal: @escaping (String, Int) -> Bool) {
        self.file = file.standardizedFileURL.resolvingSymlinksInPath()
        readUses = read
        isCurrent = current
        revealReply = reveal
    }

    /// Same byte spelling as Rust turn_sources::file_uri, including reserved path punctuation.
    public static func sourceURI(_ path: String) -> String? {
        guard path.hasPrefix("/"), let encoded = path.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/-._~")) else { return nil }
        return "file://" + encoded
    }

    public static func sourceURI(_ file: URL) -> String? { sourceURI(file.path) }

    public func matches(_ file: URL) -> Bool { file == self.file && isCurrent() }

    public func read(cursor: String?) async throws -> JSONValue {
        guard isCurrent() else { throw PageError.closed }
        let result = try await readUses(cursor)
        guard isCurrent() else { throw PageError.closed }
        if cursor == nil { shown.removeAll(keepingCapacity: true) }
        // Bounded native click validation, not another provenance store. The Rust journal is authoritative.
        if case .array(let uses)? = result["uses"] {
            for use in uses {
                guard shown.count < 1024, let turn = use["turnId"]?.stringValue,
                      let reply = use["replyId"]?.stringValue, let seq = use["seq"]?.intValue,
                      seq > 0, seq <= 9_007_199_254_740_991 else { continue }
                shown[Reply(turn: turn, reply: reply)] = seq
            }
        }
        return result
    }

    public func reveal(reply: String, turn: String) -> Bool {
        guard isCurrent(), let seq = shown[Reply(turn: turn, reply: reply)] else { return false }
        return revealReply(reply, seq)
    }
}
