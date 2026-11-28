import AppKit
@testable import CmuxNextApp
import CmuxNextDaemon
import CmuxNextHistory
import Foundation
import Testing

/// cx-bxh0 (ownership audit V-9): a hide made right after launch, before the home session's
/// `history.hidden` projection loaded, was saved with no revision, so the daemon took it as a
/// fresh document and dropped every earlier hide; the cleared entries came back. A hide before
/// the load now waits for it and saves the merge. Runs against a same-tree cmux-tui daemon.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct HiddenHistoryLoadTests {
    static func stored(_ connection: DaemonConnection) async throws -> (HiddenHistory, UInt64?) {
        let projection = try await connection.frontendProjection(subject: HiddenHistoryStore.subject)
        guard projection.projection != .null else { return (HiddenHistory(), projection.projectionRevision) }
        let document = try JSONDecoder().decode(HiddenHistory.self, from: JSONEncoder().encode(projection.projection))
        return (document, projection.projectionRevision)
    }

    @Test func aHideBeforeTheLoadKeepsEarlierHides() async throws {
        try await PinnedPageTests.withApp { services, connection in
            // An earlier session hid an entry.
            var earlier = HiddenHistory()
            earlier.hide(entry: "agent:earlier")
            let (_, revision) = try await Self.stored(connection)
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(earlier))
            try await connection.putFrontendProjection(subject: HiddenHistoryStore.subject, schemaVersion: HiddenHistory.schemaVersion,
                                                       projection: value, expectedRevision: revision)

            // A fresh launch's store gets a hide before its load ran.
            let store = HiddenHistoryStore(services: services)
            store.change { $0.hide(entry: "agent:new") }

            let deadline = ContinuousClock.now + .seconds(10)
            var document = HiddenHistory()
            while ContinuousClock.now < deadline {
                document = try await Self.stored(connection).0
                if document.entries.contains("agent:new") && store.document.entries.contains("agent:earlier") { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(document.entries.contains("agent:earlier"), "the earlier hide was dropped: \(document.entries)")
            #expect(document.entries.contains("agent:new"))
            #expect(store.document.entries.contains("agent:earlier"))
        }
    }
}
