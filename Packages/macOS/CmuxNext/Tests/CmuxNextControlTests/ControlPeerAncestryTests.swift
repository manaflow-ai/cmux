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
}
