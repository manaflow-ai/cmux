import Testing
@testable import CmuxMobileTerminal

@Suite("Ghostty semantic consumers")
struct GhosttySemanticConsumerPolicyTests {
    @Test(arguments: GhosttySemanticConsumer.allCases)
    func authoritativeGridFailsClosed(_ consumer: GhosttySemanticConsumer) {
        #expect(!GhosttySemanticConsumerPolicy.allows(
            consumer,
            authoritativeGridActive: true
        ))
    }

    @Test(arguments: GhosttySemanticConsumer.allCases)
    func ordinaryRendererRemainsAvailable(_ consumer: GhosttySemanticConsumer) {
        #expect(GhosttySemanticConsumerPolicy.allows(
            consumer,
            authoritativeGridActive: false
        ))
    }
}
