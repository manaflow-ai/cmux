import Testing
@testable import CmuxFoundation

@Suite("SSH destination arguments")
struct StringSSHDestinationTests {
    @Test("Option-like SSH destinations are detected")
    func optionLikeDestinations() {
        #expect("-oProxyCommand=x".isOptionLikeSSHDestination)
        #expect("  -p22".isOptionLikeSSHDestination)
        #expect(!"alice@host-1".isOptionLikeSSHDestination)
        #expect(!"host".isOptionLikeSSHDestination)
    }
}
