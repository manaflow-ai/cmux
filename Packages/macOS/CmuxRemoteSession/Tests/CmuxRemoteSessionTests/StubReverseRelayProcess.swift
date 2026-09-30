@testable import CmuxRemoteSession

/// Immutable fake process used by the injected launcher.
final class StubReverseRelayProcess:
    RemoteReverseRelayProcess,
    @unchecked Sendable
{
    let isRunning = true
    let terminationStatus: Int32 = 0

    func terminate() {}
}
