import Foundation
import Testing
@testable import CmuxNextDaemon

struct AgentInventoryWatchRevisionTests {
    private func decode(revision: String, machine: String = "machine_0123456789abcdef0123456789abcdef",
                        watch: String = "inventory_watch_0123456789abcdef0123456789abcdef") -> JSONValue {
        let line = #"{"event":"agent-inventory-changed","machine":"\#(machine)","watch_id":"\#(watch)","revision":\#(revision),"diagnostics":"private@example.test secret-token"}"#
        guard case .unknown("agent-inventory-changed", let payload) = DaemonEvent.decode(
            name: "agent-inventory-changed", line: Data(line.utf8)
        ) else {
            Issue.record("inventory notices must remain on the side-event channel")
            return .null
        }
        return payload
    }

    @Test(arguments: ["0", "9007199254740993", "18446744073709551615"])
    func nativeRevisionsSurviveTheGenericJSONBoundaryExactly(revision: String) {
        let payload = decode(revision: revision)
        #expect(payload["revision"]?.stringValue == revision,
                "preserve the exact decimal UInt64 before JSONValue can round it")
        #expect(payload["diagnostics"] == nil, "only lease identity and revision belong on this channel")
    }

    @Test(arguments: ["-1", "1.5", "true", "\"1\"", "null", "18446744073709551616"])
    func invalidWireRevisionsNeverBecomeLeaseNotices(revision: String) {
        #expect(decode(revision: revision) == .null)
    }

    @Test(arguments: ["machine_short", "machine_0123456789ABCDEF0123456789ABCDEF", "surface_0123456789abcdef0123456789abcdef"])
    func foreignOrAbbreviatedOwnerIDsNeverBecomeLeaseNotices(machine: String) {
        #expect(decode(revision: "1", machine: machine) == .null)
    }

    @Test(arguments: ["old", "inventory_watch_0123456789ABCDEF0123456789ABCDEF", "inventory_watch_0123456789abcdef0123456789abcde"])
    func malformedLeaseIDsNeverBecomeLeaseNotices(watch: String) {
        #expect(decode(revision: "1", watch: watch) == .null)
    }

    @Test func unrelatedUnknownEventsKeepTheirExistingNumberShape() {
        let data = Data(#"{"event":"unrelated-test-event","revision":2}"#.utf8)
        let event = DaemonEvent.decode(name: "unrelated-test-event", line: data)
        guard case .unknown(_, let payload) = event else { Issue.record("unknown event"); return }
        #expect(payload["revision"] == .number(2))
    }
}
