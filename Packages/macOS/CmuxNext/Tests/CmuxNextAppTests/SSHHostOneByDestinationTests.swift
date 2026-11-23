import CmuxNextRemote
import Testing

/// "Connect to Machine: devbox" passes only the destination, so its row must name the machine a
/// destination-only connect reuses: one per host, user and port, the default session first.
@Suite struct SSHHostOneByDestinationTests {
    private func host(_ text: String, session: String = RemoteSessionName.defaultName) throws -> SSHHost {
        try SSHHost(destination: SSHDestination(parsing: text), session: session)
    }

    @Test func oneHostPerDestinationTheDefaultSessionFirst() throws {
        let named = try host("me@devbox", session: "work")
        let main = try host("me@DevBox")
        let other = try host("me@devbox:2222")
        let lone = try host("studio", session: "agents")
        let picked = [named, other, main, lone].oneByDestination
        #expect(picked.map(\.machineID) == [main.machineID, other.machineID, lone.machineID])
        #expect(picked.last?.label == "studio/agents", "a host with only a named session is still its destination's machine")
    }
}
