import Testing
@testable import CmuxNextRemote

/// cx-zdh8 / cx-0b8z: when the machine's cmux-tui does not start, ssh passes
/// its error to the link's stderr before the local client's last line
/// ("all remote route candidates failed: ... link closed during
/// handshake"). The link failure keeps the cause, not only that last line.
struct SSHLinkFailureTextTests {
    static let stderr = """
    cmux-tui: could not prepare secure daemon state directory /dev/null/cmux-state/sessions/bWFpbg: Not a directory (os error 20)
    cmux-tui: all remote route candidates failed: ssh://100.106.216.105: link closed during handshake
    """

    @Test func aRemoteFailureOfTheLinkKeepsTheDaemonsCause() {
        let failure = SSHFailure.classifyLink(stderr: Self.stderr)
        guard case let .remoteFailed(text) = failure else { Issue.record("\(String(describing: failure))"); return }
        #expect(text.contains("could not prepare secure daemon state directory"))
        #expect(text.contains("link closed during handshake"))
    }

    @Test func sshsOwnFailuresKeepTheirOneLine() {
        let failure = SSHFailure.classifyLink(stderr: "debug: x\nec2-user@host: Permission denied (publickey).")
        #expect(failure == .authFailed("ec2-user@host: Permission denied (publickey)."))
    }

    @Test func theCauseIsBounded() {
        let long = (1...40).map { "cmux-tui: line \($0)" }.joined(separator: "\n")
        guard case let .remoteFailed(text) = SSHFailure.classifyLink(stderr: long) else { Issue.record("not remote"); return }
        #expect(text.split(separator: "\n").count <= SSHFailure.linkCauseLines)
        #expect(text.hasSuffix("cmux-tui: line 40"))
    }
}
