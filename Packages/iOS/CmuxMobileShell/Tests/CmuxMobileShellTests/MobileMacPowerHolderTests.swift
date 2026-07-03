import Foundation
import Testing
@testable import CmuxMobileShell

@Suite struct MobileMacPowerHolderTests {
    @Test func decodedHoldersWithoutPidsKeepDistinctIdentities() throws {
        let data = Data("""
        [
          {
            "process": "caffeinate",
            "types": ["PreventUserIdleSystemSleep"],
            "detail": "assertion one"
          },
          {
            "process": "backupd",
            "types": ["PreventSystemSleep"],
            "detail": "assertion two"
          }
        ]
        """.utf8)

        let holders = try JSONDecoder().decode([MobileMacPowerHolder].self, from: data)

        #expect(holders.map(\.pid) == [0, 0])
        #expect(Set(holders.map(\.id)).count == holders.count)
    }
}
