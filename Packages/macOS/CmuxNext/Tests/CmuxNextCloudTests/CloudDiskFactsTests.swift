@testable import CmuxNextCloud
import CmuxNextDaemon
import Foundation
import Testing

/// The record's disk report (cmux-cloud-machine `Machine.disk`) goes to the Cloud rules as the JSON it came
/// as (RFD 0068 disk bar): the app reads none of it, and byte counts stay whole numbers, which the Rust
/// rules read as `u64`.
@Suite struct CloudDiskFactsTests {
    @Test func aRecordsDiskPassesOnAsItsJSON() throws {
        var machine = CloudMachine(id: "vm-1", status: .running, displayName: "Disk")
        #expect(machine.diskFacts == nil)
        let json = Data(#"{"total_bytes": 21474836480, "used_bytes": 10737418240, "caches_bytes": 1073741824}"#.utf8)
        machine.disk = try JSONDecoder().decode(JSONValue.self, from: json)
        let facts = try #require(machine.diskFacts as? [String: Any])
        #expect(facts.count == 3)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), as: UTF8.self)
        #expect(text == #"{"caches_bytes":1073741824,"total_bytes":21474836480,"used_bytes":10737418240}"#)
    }
}
