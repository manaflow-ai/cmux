import Foundation
import Testing
@testable import CMUXAgentLaunch

@Suite("Mobile workstream revision")
struct WorkstreamFeedRevisionTests {
    @Test("Mobile Feed keeps its legacy revision namespace during migration")
    func mobileFeedRevisionPreservesLegacyNamespace() {
        let cachedRevision = WorkstreamFeedRevision(workstream: 12).value
        let upgradedRevision = WorkstreamFeedRevision(workstream: 13).value

        #expect(cachedRevision == ((12 << 32) | 0xFFFF_FFFF))
        #expect(upgradedRevision > cachedRevision)
    }

    @Test("Mobile Feed revision stays signed when the persisted log exceeds 2 GiB")
    func mobileFeedRevisionContinuesPastSignedBoundary() {
        let beforeBoundary = WorkstreamFeedRevision(workstream: 2_147_483_647).value
        let atBoundary = WorkstreamFeedRevision(workstream: 2_147_483_648).value

        #expect(beforeBoundary >= 0)
        #expect(atBoundary == beforeBoundary + 1)

        let later = WorkstreamFeedRevision(workstream: 2_147_483_649).value
        #expect(later > atBoundary)
    }

    @Test("Mobile Feed revision crosses the compatibility cutover monotonically")
    func mobileFeedRevisionCutoverIsMonotonic() {
        let before = WorkstreamFeedRevision(workstream: 1_073_741_823).value
        let after = WorkstreamFeedRevision(workstream: 1_073_741_824).value
        #expect(after > before)
    }

    @Test("Mobile Feed revision never drops below a revision an older Mac sent")
    func mobileFeedRevisionCoversLegacyPackedValues() {
        // An older Mac sent (workstream << 32) | notifications, or the bare
        // workstream revision before notification history loaded.
        for notifications in [0, 1, 7, 0xFFFF_FFFF] {
            let legacy = notifications > 0 ? (12 << 32) | notifications : 12
            #expect(WorkstreamFeedRevision(workstream: 12).value >= legacy)
        }
    }

    @Test("A multi-GB journal remains newer than its legacy row-count validator", arguments: [
        1_073_741_824, 2_147_483_648, 3_328_599_654, 17_179_869_184
    ])
    func migrationUsesRowCountRatherThanByteCountAsLegacyInput(bytes: Int) {
        // Even the mandatory UUID plus JSON key names exceed 64 bytes per row.
        // This upper bound on legacy rows is deliberately more conservative
        // than real persisted events, which are hundreds of bytes or larger.
        let legacyRows = bytes / 64
        let highestLegacyValidator = (legacyRows << 32) | 0xFFFF_FFFF
        let current = WorkstreamFeedRevision(workstream: bytes).value
        #expect(current > highestLegacyValidator)
        #expect(WorkstreamFeedRevision(workstream: bytes + 1).value > current)
    }

    @Test("Revision saturates without trapping at the integer limit")
    func saturatesAtIntegerLimit() {
        #expect(WorkstreamFeedRevision(workstream: Int.max).value == Int.max)
        #expect(WorkstreamFeedRevision(workstream: -1).value == WorkstreamFeedRevision(workstream: 0).value)
    }
}
