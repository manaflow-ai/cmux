import CmuxNextAgentPane
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// Native-only provenance of a local file open. The Markdown page never chooses a socket,
/// session or tab. Navigating to another file does not transfer this capability to it.
@MainActor
final class FilePageSourceContext {
    let id = UUID().uuidString
    private let file: URL
    private let readUses: (String?) async throws -> JSONValue
    private let isCurrent: () -> Bool
    private let revealReply: (String, Int) -> Bool
    private struct Reply: Hashable { let turn: String; let reply: String }
    private var shown: [Reply: Int] = [:]

    convenience init?(file: URL, view: AgentPaneView, tab: String, machine: String, services: AppServices) {
        guard file.isFileURL, view.model.canReadSourceUses, let session = view.model.sessionId,
              let uri = Self.sourceURI(file) else { return nil }
        self.init(file: file, read: { [weak view] cursor in
            guard let view else { throw PageError.closed }
            return try await view.model.sourceUses(uri: uri, session: session, cursor: cursor)
        }, current: { [weak view] in
            view?.model.sessionId == session && view?.model.canReadSourceUses == true
        }, reveal: { [weak view, weak services] reply, seq in
            guard let view, view.model.sessionId == session, view.model.canReadSourceUses,
                  services?.revealTab(tab, onMachine: machine) == true else { return false }
            let target: JSONValue = ["replyId": .string(reply), "seq": JSONValue(seq)]
            view.revealTurn("source-reply:" + target.compactText)
            return true
        })
    }

    /// Explicit dependencies keep the authority boundary testable without a running app or daemon.
    init(file: URL, read: @escaping (String?) async throws -> JSONValue,
         current: @escaping () -> Bool, reveal: @escaping (String, Int) -> Bool) {
        self.file = file.standardizedFileURL.resolvingSymlinksInPath()
        readUses = read
        isCurrent = current
        revealReply = reveal
    }

    /// Same byte spelling as Rust turn_sources::file_uri, including reserved path punctuation.
    static func sourceURI(_ file: URL) -> String? {
        guard file.isFileURL, let path = file.path.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789/-._~")) else { return nil }
        return "file://" + path
    }

    func matches(_ file: URL) -> Bool { file == self.file && isCurrent() }

    func read(cursor: String?) async throws -> JSONValue {
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

    func reveal(reply: String, turn: String) -> Bool {
        guard isCurrent(), let seq = shown[Reply(turn: turn, reply: reply)] else { return false }
        return revealReply(reply, seq)
    }
}
