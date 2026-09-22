import Foundation
import Testing

@testable import CMUXMobileCore

@MainActor
@Suite("Mobile terminal stream state")
struct MobileTerminalStreamStateStoreTests {
    @Test func appendAdvancesCursorAndRetainsOnlyTheReplayTail() {
        let store = MobileTerminalStreamStateStore(replayBudget: 8)
        let surfaceID = UUID()

        let first = store.append(surfaceID: surfaceID, data: Data("abc".utf8))
        let second = store.append(surfaceID: surfaceID, data: Data("defghijk".utf8))

        #expect(first == MobileTerminalStreamAppendResult(chunkSequence: 0, currentSequence: 3))
        #expect(second == MobileTerminalStreamAppendResult(chunkSequence: 3, currentSequence: 11))
        #expect(store.currentSequence(surfaceID: surfaceID) == 11)
        #expect(store.replayState(surfaceID: surfaceID)?.seq == 11)
        #expect(store.replayState(surfaceID: surfaceID)?.data == Data("defghijk".utf8))
    }

    @Test func renderCaptureIdentityCreatesStateAndAdvancesIndependentlyOfBytes() {
        let store = MobileTerminalStreamStateStore()
        let surfaceID = UUID()

        let current = store.currentRenderCaptureIdentity(surfaceID: surfaceID)
        #expect(current.revision == 0)
        #expect(store.replayState(surfaceID: surfaceID)?.seq == 0)
        #expect(store.replayState(surfaceID: surfaceID)?.data.isEmpty == true)

        let next = store.nextRenderCaptureIdentity(surfaceID: surfaceID)
        #expect(next.epoch == current.epoch)
        #expect(next.revision == 1)
        #expect(store.currentSequence(surfaceID: surfaceID) == 0)
    }

    @Test func inputWatermarkChangesOnlyForAcceptedInputAndNilClearsLegacyCorrelation() {
        let store = MobileTerminalStreamStateStore()
        let surfaceID = UUID()

        store.recordAcceptedInput(surfaceID: surfaceID, sequence: 7, accepted: false)
        #expect(store.currentInputSequence(surfaceID: surfaceID) == nil)

        store.recordAcceptedInput(surfaceID: surfaceID, sequence: 9, accepted: true)
        #expect(store.currentInputSequence(surfaceID: surfaceID) == 9)

        store.recordAcceptedInput(surfaceID: surfaceID, sequence: nil, accepted: true)
        #expect(store.currentInputSequence(surfaceID: surfaceID) == nil)
    }

    @Test func removeSurfaceDropsReplayCursorRenderAndInputState() {
        let store = MobileTerminalStreamStateStore()
        let surfaceID = UUID()

        _ = store.append(surfaceID: surfaceID, data: Data([1, 2, 3]))
        _ = store.nextRenderCaptureIdentity(surfaceID: surfaceID)
        store.recordAcceptedInput(surfaceID: surfaceID, sequence: 4, accepted: true)

        store.removeSurface(surfaceID: surfaceID)

        #expect(store.replayState(surfaceID: surfaceID) == nil)
        #expect(store.currentSequence(surfaceID: surfaceID) == nil)
        #expect(store.currentInputSequence(surfaceID: surfaceID) == nil)
        #expect(store.currentRenderCaptureIdentity(surfaceID: surfaceID).revision == 0)
    }
}
