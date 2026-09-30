@testable import CmuxNextControl
import Darwin
import Testing

/// `.cmuxOnly` admits a CLI started in a cmux-next terminal. Terminals
/// descend from the cmux-tui terminal hosts (the bundled `bin/cmux`), not
/// from the app, so before this rule the app refused every one of them.
@Suite struct ControlPeerAncestryTests {
    // shell 40 <- terminal host 30 (bin/cmux) <- launchd 1; app 10; stray 50 <- 1.
    let table: [pid_t: (parent: pid_t, executable: String?)] = [
        40: (30, "/bin/zsh"),
        30: (1, "/Apps/cmux DEV x.app/Contents/Resources/bin/cmux"),
        12: (10, "/usr/bin/python3"),
        50: (1, "/usr/bin/python3"),
    ]
    var ancestry: ControlPeerAncestry {
        let table = table
        return ControlPeerAncestry { table[$0] }
    }
    let executables: Set<String> = ["/Apps/cmux DEV x.app/Contents/Resources/bin/cmux"]

    @Test func terminalProcessesAndAppChildrenAreInside() {
        #expect(ancestry.isInside(40, ancestor: 10, executables: executables))
        #expect(ancestry.isInside(12, ancestor: 10, executables: executables))
    }

    @Test func otherProcessesAreNot() {
        #expect(!ancestry.isInside(50, ancestor: 10, executables: executables))
        #expect(!ancestry.isInside(40, ancestor: 10, executables: []))
        #expect(!ancestry.isInside(99, ancestor: 10, executables: executables))
    }
}
