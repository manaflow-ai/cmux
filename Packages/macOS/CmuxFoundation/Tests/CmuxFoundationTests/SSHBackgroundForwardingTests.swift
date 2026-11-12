import Testing
@testable import CmuxFoundation

@Suite("Background ssh forwarding")
struct SSHBackgroundForwardingTests {
    @Test("Agent and X11 forwarding off keeps port forwards")
    func agentAndX11Off() {
        #expect(SSHBackgroundForwarding.agentAndX11Off.optionArguments == [
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
        ])
    }

    @Test("All forwarding off also clears configured port forwards")
    func allOff() {
        #expect(SSHBackgroundForwarding.allOff.optionArguments == [
            "-o", "ForwardAgent=no",
            "-o", "ForwardX11=no",
            "-o", "ClearAllForwardings=yes",
        ])
    }
}
