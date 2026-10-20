import CmuxNextActions
import CmuxNextServer
import Foundation

/// Add Server… from an in-process person action with explicit code and words:
/// the same intents the approver sheet sends, in the same order. The words are
/// the check a person makes in the sheet: the server prints them from its key
/// and the app derives them from the key the code names, so a swapped code never
/// matches. Without matching words nothing is approved. Socket-originated CLI,
/// MCP, script, page and remote runs are refused before this path. Event driven:
/// it waits for the source's answers, never on a timer (each cloud call has its
/// own timeout).
@MainActor
enum ServerHeadlessApproval {
    /// Approves `code` when `words` match the server's fingerprint words; nil on
    /// success, else the refusal text (never the expected words). `runChief` nil
    /// follows the server's capability (a Chief brain takes the Chief).
    static func run(source: any ServerSource, code: String, words: String?, name: String?, runChief: Bool?) async -> String? {
        let typed = Self.words(words)
        guard !typed.isEmpty else { return wordsMissing }
        let normalized = PairingCode.normalize(code)
        // One approval sees a handful of events (connection, snapshot, candidate, two settles); the cap
        // keeps the newest so a burst of status snapshots can never push out the settle it waits for.
        let events = AsyncStream<ServerSourceEvent>.makeStream(bufferingPolicy: .bufferingNewest(Self.eventBuffer))
        source.start { events.continuation.yield($0) }
        defer {
            source.stop()
            events.continuation.finish()
        }
        let lookup = ServerIntent(kind: .lookupCode(normalized))
        source.send(lookup)
        var candidate: PairingCandidate?
        var approve: ServerIntent?
        for await event in events.stream {
            switch event {
            case let .candidate(found) where found?.code == normalized:
                candidate = found
            case let .settled(key, reject) where key == lookup.key:
                if let reject { return reject }
                guard let found = candidate, let team = found.teams.first else { return notFound }
                guard typed == found.words.map({ $0.lowercased() }) else { return wordsDiffer }
                let label = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let intent = ServerIntent(kind: .approveCode(code: normalized, team: team.id, name: label.isEmpty ? found.name : label,
                                                             placeChief: runChief ?? found.isChiefBrain))
                approve = intent
                source.send(intent)
            case let .settled(key, reject) where key == approve?.key:
                return reject
            default:
                continue
            }
        }
        return notFound
    }

    /// The code and words authenticate the waiting server, not the approver. Only an in-process
    /// user action may turn them into account authority; every socket/page caller is refused.
    nonisolated static func allows(origin: ActionOrigin) -> Bool {
        origin == .user
    }

    /// Events one headless approval may hold before the oldest are dropped.
    static let eventBuffer = 64

    /// The words as typed, in order: case and separators (spaces, commas, hyphens) ignored.
    static func words(_ text: String?) -> [String] {
        (text ?? "").lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }

    static var notFromThisMac: String {
        RefusalStrings.text("refusal.server.pairLocalOnly", "Approve servers from this Mac only.")
    }

    private static var wordsMissing: String {
        RefusalStrings.text("refusal.server.pairWordsMissing", "Pass the four words the server shows with the code.")
    }

    private static var wordsDiffer: String {
        RefusalStrings.text("refusal.server.pairWordsDiffer", "The words do not match that server. Nothing was approved.")
    }

    private static var notFound: String { RefusalStrings.text("refusal.server.pairNotFound", "No server is waiting with that code.") }
}
