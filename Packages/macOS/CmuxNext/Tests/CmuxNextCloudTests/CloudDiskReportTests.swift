import Foundation
import Testing
@testable import CmuxNextCloud

/// The record's disk report (cmux-cloud-machine `Machine.disk`) decodes and goes to the Cloud rules as
/// the crate's own names (RFD 0068 disk bar).
@Suite struct CloudDiskReportTests {
    @Test func aRecordsDiskDecodesAndPassesOnItsFields() throws {
        let json = Data(#"{"total_bytes": 21474836480, "used_bytes": 10737418240, "caches_bytes": 1073741824}"#.utf8)
        let report = try JSONDecoder().decode(CloudDiskReport.self, from: json)
        #expect(report.usedBytes == 10_737_418_240)
        #expect(report.systemBytes == nil)
        let facts = report.facts
        #expect(facts.count == 3)
        #expect(facts["caches_bytes"] as? UInt64 == 1_073_741_824)
    }

    /// The protocol names the allocation `size.disk_mb` (CloudMachineSize); the bar's "of 20 GB" reads it.
    @Test func aNextRecordsSizeCarriesItsDiskAllocation() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let size = try decoder.decode(CloudMachine.Size.self, from: Data(#"{"cpu": 2, "disk_mb": 20480}"#.utf8))
        #expect(size.diskMb == 20_480)
        #expect(size.storageMb == nil)
    }
}
