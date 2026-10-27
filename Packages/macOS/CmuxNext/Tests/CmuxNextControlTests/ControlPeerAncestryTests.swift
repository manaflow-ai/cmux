@testable import CmuxNextControl
import Darwin
import Testing

@Suite struct ControlPeerAncestryTests {
    @Test func trustedExecutableMustBeAnAncestorRatherThanThePeerItself() {
        let trusted = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        let processes: [pid_t: (parent: pid_t, executable: String?)] = [
            40: (1, trusted),
            41: (40, "/bin/zsh"),
        ]
        let ancestry = ControlPeerAncestry { processes[$0] }

        #expect(!ancestry.isInside(40, ancestor: 999, executables: [trusted]))
        #expect(ancestry.isInside(41, ancestor: 999, executables: [trusted]))
        #expect(ancestry.isInside(40, ancestor: 40, executables: []))
    }

    /// The Credential Vault's caller check reads this, not a request's params (cmux issue 26412):
    /// an agent's `cmux` keeps acpmux in its lineage whatever env it runs with, and a process that
    /// left cmux (a double fork to launchd) is outside.
    @Test func aConnectionsLineageNamesEveryProcessUpToTheCmuxThatStartedIt() {
        let trusted = "/Applications/cmux.app/Contents/Resources/bin/cmux"
        let processes: [pid_t: (parent: pid_t, executable: String?)] = [
            40: (1, trusted),
            41: (40, "/Applications/cmux.app/Contents/Resources/bin/acpmux"),
            42: (41, "/Users/me/.local/share/claude/versions/2.1.30"),
            43: (42, "/bin/zsh"),
            44: (43, trusted),
            50: (1, trusted),
        ]
        let ancestry = ControlPeerAncestry { processes[$0] }
        let agent = ancestry.lineage(44, ancestor: 999, executables: [trusted])
        #expect(agent == .init(insideCmux: true, executables: ["cmux", "zsh", "2.1.30", "acpmux", "cmux"]))
        #expect(ancestry.lineage(50, ancestor: 999, executables: [trusted]) == .init(insideCmux: false, executables: ["cmux"]))

        let peers = ControlConnectionPeers(ancestry: ancestry)
        let connection = ControlConnectionID(rawValue: 7)
        #expect(peers.lineage(connection) == nil, "no peer was recorded")
        peers.opened(connection, pid: 44, ancestor: 999, trusted: [trusted])
        #expect(peers.lineage(connection) == agent)
        peers.closed(connection)
        #expect(peers.lineage(connection) == nil)
        #expect(peers.lineage(.inProcess) == nil)
    }
}
