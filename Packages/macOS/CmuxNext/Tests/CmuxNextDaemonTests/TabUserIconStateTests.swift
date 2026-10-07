import Foundation
import Testing
@testable import CmuxNextDaemon

/// ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS: the icon a user sets on a tab lives on
/// the daemon's tab record (`extra.icon`). A snapshot puts it on the tab, a later
/// tab upsert without it removes it, so every client shows the same icon.
@MainActor @Suite struct TabUserIconStateTests {
    typealias State = SessionStateTests

    private func event(_ line: String) -> DaemonEvent {
        DaemonEvent.decode(name: LineTransport.streamEvent, line: Data(line.utf8))
    }

    private func tab(_ store: DaemonStore) throws -> TabModel {
        try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first {
            $0.resourceID?.rawValue == State.tab
        })
    }

    @Test func aTabRecordIconReachesTheTabAndAnUpsertWithoutItClearsIt() throws {
        let store = DaemonStore()
        store.apply(snapshot: try Fixture.response(DaemonTree.self, "list-workspaces.json"))
        let snapshot = State.snapshot.replacingOccurrences(of: #""extra":{"zoom":1.5}"#,
                                                             with: #""extra":{"zoom":1.5,"icon":"hammer.fill"}"#)
        #expect(snapshot != State.snapshot)
        store.apply(batch: [DaemonEventEnvelope(sequence: 1, event: event(snapshot))])
        #expect(try tab(store).userIcon == "hammer.fill")
        #expect(try tab(store).zoom == 1.5)

        let emoji = State.item(#"""
        {"kind":"delta","cursor":{"generation":"g","revision":"5"},"previous_revision":"4","revision":"5","changes":[
          {"kind":"upsert","sequence":0,"resource":"tab","id":"\#(State.tab)","value":{"id":"\#(State.tab)","pane_id":"pane_p","name":null,"index":0,"focused":true,"content_kind":"terminal","content_id":"\#(State.terminal)","extra":{"icon":"🚀"}}}
        ]}
        """#)
        store.apply(batch: [DaemonEventEnvelope(sequence: 2, event: event(emoji))])
        #expect(try tab(store).userIcon == "🚀")
        #expect(try tab(store).zoom == nil)

        let cleared = State.item(#"""
        {"kind":"delta","cursor":{"generation":"g","revision":"6"},"previous_revision":"5","revision":"6","changes":[
          {"kind":"upsert","sequence":0,"resource":"tab","id":"\#(State.tab)","value":{"id":"\#(State.tab)","pane_id":"pane_p","name":null,"index":0,"focused":true,"content_kind":"terminal","content_id":"\#(State.terminal)","extra":{}}}
        ]}
        """#)
        store.apply(batch: [DaemonEventEnvelope(sequence: 3, event: event(cleared))])
        #expect(try tab(store).userIcon == nil)
    }
}
