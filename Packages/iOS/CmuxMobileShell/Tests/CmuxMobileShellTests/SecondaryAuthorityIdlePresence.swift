import CmuxMobileShellModel
@testable import CmuxMobileShell

struct SecondaryAuthorityIdlePresence: PresenceSubscribing {
    func subscribe() async throws
        -> AsyncThrowingStream<PresenceUpdate, any Error> {
        AsyncThrowingStream { _ in }
    }
}
