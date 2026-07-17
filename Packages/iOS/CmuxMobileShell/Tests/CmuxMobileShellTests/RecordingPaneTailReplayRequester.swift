@testable import CmuxMobileShell

@MainActor
final class RecordingPaneTailReplayRequester: PaneTailReplayRequesting {
    private(set) var surfaceIDs: [String] = []

    func requestPaneTailReplay(surfaceID: String) {
        surfaceIDs.append(surfaceID)
    }
}
