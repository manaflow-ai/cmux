import Foundation

extension WorkspaceRemoteSessionController {
    static let remotePlatformProbeHomeMarker = "__CMUX_REMOTE_HOME__="
    static let remotePlatformProbeOSMarker = "__CMUX_REMOTE_OS__="
    static let remotePlatformProbeArchMarker = "__CMUX_REMOTE_ARCH__="
    static let remotePlatformProbeExistsMarker = "__CMUX_REMOTE_EXISTS__="

    /// Builds the remote shell probe that reports platform and daemon availability markers.
    static func remotePlatformProbeScript(version: String) -> String {
        let scriptVersion = normalizedRemotePlatformProbeVersion(version)
        return """
        cmux_uname_os="$(uname -s)"
        cmux_uname_arch="$(uname -m)"
        printf '%s%s\\n' '\(Self.remotePlatformProbeHomeMarker)' "$HOME"
        printf '%s%s\\n' '\(Self.remotePlatformProbeOSMarker)' "$cmux_uname_os"
        printf '%s%s\\n' '\(Self.remotePlatformProbeArchMarker)' "$cmux_uname_arch"
        case "$cmux_uname_os" in
          Linux|linux|LINUX) cmux_go_os=linux ;;
          Darwin|darwin|DARWIN) cmux_go_os=darwin ;;
          FreeBSD|freebsd|FREEBSD) cmux_go_os=freebsd ;;
          *) exit 70 ;;
        esac
        case "$cmux_uname_arch" in
          x86_64|X86_64|amd64|AMD64) cmux_go_arch=amd64 ;;
          aarch64|AARCH64|arm64|ARM64) cmux_go_arch=arm64 ;;
          armv7l|ARMV7L|armv7|ARMV7) cmux_go_arch=arm ;;
          *) exit 71 ;;
        esac
        cmux_remote_path="$HOME/.cmux/bin/cmuxd-remote/\(scriptVersion)/${cmux_go_os}-${cmux_go_arch}/cmuxd-remote"
        if [ -x "$cmux_remote_path" ]; then
          printf '%syes\\n' '\(Self.remotePlatformProbeExistsMarker)'
        else
          printf '%sno\\n' '\(Self.remotePlatformProbeExistsMarker)'
        fi
        """
    }

    /// Returns stdout suitable for user-facing error details by removing internal probe markers.
    static func remotePlatformProbeUserFacingStdout(_ stdout: String) -> String {
        stdout
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isRemotePlatformProbeMarkerLine(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            .joined(separator: "\n")
    }

    /// Normalizes the daemon version path segment before it is interpolated into remote shell.
    private static func normalizedRemotePlatformProbeVersion(_ version: String) -> String {
        guard !version.isEmpty,
              version.count <= 128,
              version != ".",
              version != ".." else {
            return "dev"
        }
        let isSafePathSegment = version.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) ||
                byte == 45 ||
                byte == 46 ||
                byte == 95
        }
        return isSafePathSegment ? version : "dev"
    }

    /// Returns true when a line is one of the internal markers emitted by the probe.
    private static func isRemotePlatformProbeMarkerLine(_ line: String) -> Bool {
        line.hasPrefix(remotePlatformProbeHomeMarker) ||
            line.hasPrefix(remotePlatformProbeOSMarker) ||
            line.hasPrefix(remotePlatformProbeArchMarker) ||
            line.hasPrefix(remotePlatformProbeExistsMarker)
    }
}
