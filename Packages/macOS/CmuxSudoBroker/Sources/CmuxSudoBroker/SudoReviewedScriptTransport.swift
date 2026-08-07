import Foundation

/// Describes the PTY handshake that transfers reviewed bytes after sudo authenticates.
struct SudoReviewedScriptTransport: Sendable, Equatable {
    static let readinessMarker = "__CMUX_SUDO_SCRIPT_READY__"
    static let sourcedScriptCommand = "source /dev/fd/4"
    static let bootstrap = """
    set -eu
    umask 077
    temporary=$(/usr/bin/mktemp "$2")
    trap '/bin/rm -f "$temporary"' EXIT HUP INT TERM
    exec 3>"$temporary"
    exec 4<"$temporary"
    /bin/rm -f "$temporary"
    trap - EXIT HUP INT TERM
    /bin/stty raw -echo
    /usr/bin/printf '%s' '__CMUX_SUDO_SCRIPT_READY__'
    /bin/dd bs=1 count="$1" of=/dev/fd/3 2>/dev/null
    actual=$(/usr/bin/stat -f '%z' /dev/fd/3)
    [ "$actual" = "$1" ] || exit 125
    exec 3>&-
    /bin/stty sane
    exec /bin/bash -c 'source /dev/fd/4' "$0"
    """

    let reviewedScript: Data
    let approvedScriptURL: URL
    let secureTemporaryDirectoryURL: URL

    init(
        reviewedScript: Data,
        approvedScriptURL: URL,
        secureTemporaryDirectoryURL: URL = URL(fileURLWithPath: "/var/root", isDirectory: true)
    ) {
        self.reviewedScript = reviewedScript
        self.approvedScriptURL = approvedScriptURL
        self.secureTemporaryDirectoryURL = secureTemporaryDirectoryURL
    }

    var shellArguments: [String] {
        [
            "/bin/bash",
            "-c",
            Self.bootstrap,
            approvedScriptURL.standardizedFileURL.path,
            String(reviewedScript.count),
            secureTemporaryDirectoryURL
                .appendingPathComponent(".cmux-sudo.XXXXXX")
                .path,
        ]
    }
}
