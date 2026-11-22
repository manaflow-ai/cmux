@testable import CmuxNextDaemon
import Foundation
import Testing

/// SSH hosts the user entered are kept in personal state before their first
/// successful connect (the session registry needs the remote session id).
@Suite struct SavedHostsDocumentTests {
    static func fields(_ destination: String) -> [String: String] {
        ["kind": "ssh", "destination": destination, "session": "main", "remote_binary": "~/.local/bin/cmux-tui"]
    }

    @Test func upsertKeepsOneEntryPerMachineInEntryOrder() {
        var document = SavedHostsDocument()
        document.upsert(id: "ssh-a", transport: Self.fields("a.example"), nowMs: 1)
        document.upsert(id: "ssh-b", transport: Self.fields("b.example"), nowMs: 2)
        var changed = Self.fields("a.example")
        changed["connect"] = "false"
        document.upsert(id: "ssh-a", transport: changed, nowMs: 3)
        #expect(document.hosts.map(\.id) == ["ssh-a", "ssh-b"])
        #expect(document.hosts.first?.transport["connect"] == "false")
        // The first entry time is kept: it orders the saved list.
        #expect(document.hosts.first?.addedMs == 1)
        document.remove(id: "ssh-a")
        #expect(document.hosts.map(\.id) == ["ssh-b"])
    }

    @Test func theListIsBoundedDroppingTheOldest() {
        var document = SavedHostsDocument()
        for index in 0..<(SavedHostsDocument.limit + 3) {
            document.upsert(id: "ssh-\(index)", transport: Self.fields("h\(index)"), nowMs: UInt64(index))
        }
        #expect(document.hosts.count == SavedHostsDocument.limit)
        #expect(document.hosts.first?.id == "ssh-3")
    }

    /// After the first connect the session registry holds the host; the
    /// saved entry is dropped so there is one source.
    @Test func registeredHostsLeaveThePendingList() {
        var document = SavedHostsDocument()
        document.upsert(id: "ssh-a", transport: Self.fields("a.example"), nowMs: 1)
        document.upsert(id: "ssh-b", transport: Self.fields("b.example"), nowMs: 2)
        #expect(document.pending(registered: ["ssh-a"]).map(\.id) == ["ssh-b"])
        #expect(document.pruned(registered: ["ssh-a"]) == true)
        #expect(document.hosts.map(\.id) == ["ssh-b"])
        #expect(document.pruned(registered: ["ssh-a"]) == false)
    }

    @Test func roundTripsThroughTheProjectionJSON() throws {
        var document = SavedHostsDocument()
        document.upsert(id: "ssh-a", transport: Self.fields("a.example"), nowMs: 42)
        let decoded = try SavedHostsDocument(jsonValue: document.jsonValue())
        #expect(decoded == document)
        // Unknown or missing fields decode to an empty list, never a failure.
        #expect(try SavedHostsDocument(jsonValue: .object([:])).hosts.isEmpty)
    }
}
