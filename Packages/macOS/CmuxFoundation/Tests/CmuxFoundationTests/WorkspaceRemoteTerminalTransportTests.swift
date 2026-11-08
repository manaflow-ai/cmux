import Testing
@testable import CmuxFoundation

@Suite("Remote workspace terminal transport")
struct WorkspaceRemoteTerminalTransportTests {
    @Test("CLI values are case-insensitive and whitespace-tolerant")
    func cliValueParsing() {
        #expect(WorkspaceRemoteTerminalTransport(cliValue: "ssh") == .ssh)
        #expect(WorkspaceRemoteTerminalTransport(cliValue: " MOSH\n") == .mosh)
        #expect(WorkspaceRemoteTerminalTransport(cliValue: "udp") == nil)
    }
}
