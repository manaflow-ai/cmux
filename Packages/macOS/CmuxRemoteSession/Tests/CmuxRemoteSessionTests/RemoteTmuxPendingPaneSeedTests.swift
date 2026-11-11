import Foundation
import Testing

@testable import CmuxRemoteSession

@Suite struct RemoteTmuxPendingPaneSeedTests {
    @Test func liveOutputIsKeptOnTheSideOfTheCaptureItArrivedOn() {
        var seed = RemoteTmuxPendingPaneSeed(id: UUID(), kind: .fullHistory, snapshot: Data())
        seed.retainLiveOutput(Data("ab".utf8))
        seed.retainLiveOutput(Data("c".utf8))
        seed.snapshot.append(Data("screen".utf8))
        seed.isCaptureInstalled = true
        seed.retainLiveOutput(Data("d".utf8))

        #expect(seed.discardedOutput == [Data("abc".utf8)])
        #expect(seed.catchUpOutput == [Data("d".utf8)])
        #expect(seed.bufferedLiveByteCount == 4)
        #expect(seed.retainedByteCount == 10)
    }

    @Test func joiningACatchUpDropsThePreCaptureOutputAndReportsItsBytes() {
        var seed = RemoteTmuxPendingPaneSeed(id: UUID(), kind: .visibleRepaint, snapshot: Data())
        seed.retainLiveOutput(Data("stale".utf8))
        #expect(seed.canJoinCatchUp)
        #expect(!seed.dropsLiveOutput)

        let released = seed.joinCatchUp()

        #expect(released == 5)
        #expect(seed.discardedOutput.isEmpty)
        #expect(seed.bufferedLiveByteCount == 0)
        #expect(seed.dropsLiveOutput)
        seed.isCaptureInstalled = true
        #expect(!seed.dropsLiveOutput, "output after the capture is newer than it and must be kept")
        #expect(!seed.canJoinCatchUp)
    }
}
