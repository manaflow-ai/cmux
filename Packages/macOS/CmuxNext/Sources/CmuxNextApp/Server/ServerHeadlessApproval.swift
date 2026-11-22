import CmuxNextServer
import Foundation

/// Add Server… without a window (`cmux action run server.addServer --arg code=…`):
/// the same intents the approver sheet sends, in the same order: look the code
/// up, then approve it into the candidate's team. Event driven: it waits for
/// the source's answers, never on a timer (each cloud call has its own timeout).
@MainActor
enum ServerHeadlessApproval {
    /// Approves `code`; nil on success, else the refusal text. `runChief` nil
    /// follows the server's capability (a Chief brain takes the Chief).
    static func run(source: any ServerSource, code: String, name: String?, runChief: Bool?) async -> String? {
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

    /// Events one headless approval may hold before the oldest are dropped.
    static let eventBuffer = 64

    private static var notFound: String { RefusalStrings.text("refusal.server.pairNotFound", "No server is waiting with that code.") }
}
