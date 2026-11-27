import CmuxRemoteWorkspace
@testable import CmuxRemoteSession

actor RecordingImmediateClock: RemoteProxyRetryClock {
    private(set) var requestedDelays: [Int] = []

    func sleep(forMilliseconds milliseconds: Int) async throws {
        requestedDelays.append(milliseconds)
    }
}
