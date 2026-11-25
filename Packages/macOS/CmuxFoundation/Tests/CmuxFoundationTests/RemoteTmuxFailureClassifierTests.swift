import Testing
@testable import CmuxFoundation

/// How a failed remote tmux command's stderr is read (#15022). A named server (`tmux -L`)
/// makes the overlong-socket-path failure reachable, and it must not be read as an idle
/// server, which would turn the failure into an empty session list.
@Suite("Remote tmux failure classifier")
struct RemoteTmuxFailureClassifierTests {
    static let longName = String(repeating: "n", count: 64)
    static let longDirectory = "/Users/dev/Library/Caches/cmux/remote-tmux-et/some-host/tmux/tmux-501"

    static let idleServer: [String] = [
        "no server running on /tmp/tmux-501/default",
        "no server running on /tmp/tmux-501/\(longName)",
        "no sessions",
        "error connecting to /tmp/tmux-501/default (No such file or directory)",
        "error connecting to /tmp/tmux-501/\(longName) (No such file or directory)",
        "NO SERVER RUNNING ON /tmp/tmux-501/default",
    ]

    static let overlongSocketPath: [String] = [
        "error connecting to \(longDirectory)/\(longName) (File name too long)",
        "Error connecting to \(longDirectory)/\(longName) (FILE NAME TOO LONG)",
        "tmux: error connecting to \(longDirectory)/\(longName) (File name too long)\n",
        "Warning: Permanently added 'host' to known hosts.\nerror connecting to \(longDirectory)/\(longName) (File name too long)  \r\n",
    ]

    /// Failures whose socket path contains the words of the overlong-path reason, but whose
    /// actual reason, at the end of the line, is something else.
    static let reasonTextInsideThePath: [String] = [
        "error connecting to /tmp/file name too long/tmux-501/alpha (Permission denied)",
        "error connecting to /tmp/(file name too long)/tmux-501/alpha (Connection refused)",
    ]

    static let unrelated: [String] = [
        "",
        "Permission denied (publickey).",
        "sh: tmux: command not found",
        "File name too long",
        "error connecting to host",
    ]

    /// Every way tmux reports an idle server reads as no server, for default and named sockets.
    @Test(arguments: idleServer)
    func anIdleServerIsNoServerAndNotAnOverlongPath(_ stderr: String) {
        let classifier = RemoteTmuxFailureClassifier(stderr: stderr)
        #expect(classifier.indicatesNoServer)
        #expect(!classifier.indicatesSocketPathTooLong)
    }

    /// An overlong socket path is its own failure, whatever the casing or surrounding text.
    @Test(arguments: overlongSocketPath)
    func anOverlongSocketPathIsNeverAnIdleServer(_ stderr: String) {
        let classifier = RemoteTmuxFailureClassifier(stderr: stderr)
        #expect(classifier.indicatesSocketPathTooLong)
        #expect(!classifier.indicatesNoServer)
    }

    /// The reason is read from the end of the line: these are not overlong-path failures, and
    /// they keep whatever the idle-server reading already made of them.
    @Test(arguments: reasonTextInsideThePath)
    func aReasonSpelledInsideTheSocketPathIsNotAnOverlongPath(_ stderr: String) {
        #expect(!RemoteTmuxFailureClassifier(stderr: stderr).indicatesSocketPathTooLong)
    }

    /// Other stderr, including text that matches only half of a pattern, matches neither reading.
    @Test(arguments: unrelated)
    func otherFailuresAreNeither(_ stderr: String) {
        let classifier = RemoteTmuxFailureClassifier(stderr: stderr)
        #expect(!classifier.indicatesNoServer)
        #expect(!classifier.indicatesSocketPathTooLong)
    }
}
