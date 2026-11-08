import CmuxMobileShellModel
@testable import CmuxMobileShell

struct IdlePresence: PresenceSubscribing {
    func subscribe() async throws
        -> AsyncThrowingStream<PresenceUpdate, any Error> {
        AsyncThrowingStream { _ in }
    }
}
