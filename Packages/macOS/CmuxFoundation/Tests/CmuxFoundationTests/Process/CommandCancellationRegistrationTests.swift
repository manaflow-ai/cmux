import Testing

@testable import CmuxFoundation

@Suite struct CommandCancellationRegistrationTests {
    @Test func finishingBeforeHandlerInstallationDoesNotRetainRegistration() {
        weak var retainedRegistration: CommandCancellationRegistration?

        do {
            let registration = CommandCancellationRegistration()
            retainedRegistration = registration
            registration.finish()
            registration.install {
                registration.cancel()
            }
        }

        #expect(retainedRegistration == nil)
    }
}
