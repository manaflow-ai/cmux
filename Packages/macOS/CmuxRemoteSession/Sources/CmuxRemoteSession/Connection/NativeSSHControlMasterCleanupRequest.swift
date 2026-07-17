internal import Foundation

/// A local `ssh -O exit` request for a cmux-owned native SSH master.
public struct NativeSSHControlMasterCleanupRequest: Sendable {
    /// Arguments passed to `/usr/bin/ssh`.
    public let arguments: [String]

    /// Environment passed to the cleanup process, including an injected agent socket when present.
    public let environment: [String: String]?

    /// Advisory lock shared with foreground authentication for this master.
    public let authenticationLockPath: String?

    /// Creates a cleanup process request.
    ///
    /// - Parameters:
    ///   - arguments: Arguments passed to `/usr/bin/ssh`.
    ///   - environment: Optional process environment.
    ///   - authenticationLockPath: User-private lock path for this master.
    public init(
        arguments: [String],
        environment: [String: String]?,
        authenticationLockPath: String?
    ) {
        self.arguments = arguments
        self.environment = environment
        self.authenticationLockPath = authenticationLockPath
    }
}

extension NativeSSHControlMasterCleanupRequest {
    var processInvocation: (executableURL: URL, arguments: [String]) {
        guard let authenticationLockPath else {
            return (URL(fileURLWithPath: "/usr/bin/ssh"), arguments)
        }
        let inFlightPath = authenticationLockPath + ".inflight"
        let script = """
        exec 9>"$1" || exit 0
        /usr/bin/lockf -s -t 45 9 || exit 0
        cmux_auth_pid="$(/bin/cat -- "$2" 2>/dev/null || true)"
        case "$cmux_auth_pid" in
          ''|*[!0-9]*) ;;
          *)
            if /bin/kill -0 "$cmux_auth_pid" 2>/dev/null; then exit 0; fi
            cmux_auth_mtime="$(/usr/bin/stat -f %m -- "$2" 2>/dev/null || true)"
            cmux_now="$(/bin/date +%s)"
            case "$cmux_auth_mtime:$cmux_now" in
              *[!0-9:]*|:*) ;;
              *) if [ $((cmux_now - cmux_auth_mtime)) -le 30 ]; then exit 0; fi ;;
            esac
            ;;
        esac
        /bin/rm -f -- "$2" 2>/dev/null || true
        shift 2
        exec /usr/bin/ssh "$@"
        """
        return (
            URL(fileURLWithPath: "/bin/sh"),
            [
                "-c",
                script,
                "cmux-ssh-cleanup",
                authenticationLockPath,
                inFlightPath,
            ] + arguments
        )
    }
}
