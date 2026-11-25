@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// The record's disk report (cmux-cloud-machine `Machine.disk`) goes to the Cloud rules as the JSON it came
/// as (RFD 0068 disk bar): the app reads none of it, and byte counts stay whole numbers, which the Rust
/// rules read as `u64`.
@MainActor @Suite struct CloudDiskFactsTests {
    @Test func aRecordsDiskPassesOnAsItsJSON() throws {
        let json = Data(#"{"total_bytes": 21474836480, "used_bytes": 10737418240, "caches_bytes": 1073741824}"#.utf8)
        let disk = try JSONDecoder().decode(JSONValue.self, from: json)
        let facts = try #require(CloudHandlers.diskFacts(disk) as? [String: Any])
        #expect(facts.count == 3)
        #expect((facts["total_bytes"] as? NSNumber)?.uint64Value == 21_474_836_480)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: facts, options: [.sortedKeys]), as: UTF8.self)
        #expect(text == #"{"caches_bytes":1073741824,"total_bytes":21474836480,"used_bytes":10737418240}"#)
    }
}
