#if DEBUG
import Foundation
import Testing
@testable import CmuxMobileAgentChat

/// The launch marks' list frame under the workspaces rig: only a row it seeded takes it.
@Suite struct ListStressLaunchMarkTests {
    @Test func onlySeededRowsCountUnderTheWorkspacesRig() {
        let rig = ListStressSettings(environment: ["CMUX_MOBILE_LIST_SCREEN": "workspaces", "CMUX_MOBILE_LIST_COUNT": "150"])
        #expect(rig.countsListFrame(rowID: "ws-s0"))
        #expect(rig.countsListFrame(rowID: "ws-s149"))
        #expect(!rig.countsListFrame(rowID: "ws-cmux"), "a mock row shown before the seeding")
        #expect(!rig.countsListFrame(rowID: "ws-site"), "a mock id that shares the prefix")
        let plain = ListStressSettings(environment: [:])
        #expect(plain.countsListFrame(rowID: "ws-cmux"), "no rig: any row")
    }
}
#endif
