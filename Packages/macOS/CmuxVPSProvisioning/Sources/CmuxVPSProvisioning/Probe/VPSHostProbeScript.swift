internal import Foundation

/// Builds the single-round-trip shell probe `cmux vps` runs on a candidate
/// host, and owns the marker constants its output is parsed with.
///
/// The probe is POSIX-sh only (BusyBox-safe: no `tr` character classes, no
/// bashisms) and read-only — it never mutates the host. OS/arch mapping
/// happens in shell `case` arms mirroring the `cmux ssh` bootstrap probe in
/// `RemoteSessionCoordinator.remotePlatformProbeScript`.
public struct VPSHostProbeScript: Equatable, Sendable {
    /// Marker prefixes emitted by the probe, one `KEY=value` line each.
    public enum Marker: String, CaseIterable, Sendable {
        case home = "__CMUX_VPS_HOME__="
        case uid = "__CMUX_VPS_UID__="
        case unameOS = "__CMUX_VPS_UNAME_OS__="
        case unameArch = "__CMUX_VPS_UNAME_ARCH__="
        case goOS = "__CMUX_VPS_GOOS__="
        case goArch = "__CMUX_VPS_GOARCH__="
        case distroID = "__CMUX_VPS_DISTRO_ID__="
        case distroPretty = "__CMUX_VPS_DISTRO_PRETTY__="
        case systemd = "__CMUX_VPS_SYSTEMD__="
        case binaryExists = "__CMUX_VPS_BINARY_EXISTS__="
        case binarySHA256 = "__CMUX_VPS_BINARY_SHA256__="
        case currentLink = "__CMUX_VPS_CURRENT_LINK__="
        case unitPresent = "__CMUX_VPS_UNIT_PRESENT__="
        case unitSHA256 = "__CMUX_VPS_UNIT_SHA256__="
        case unitActive = "__CMUX_VPS_UNIT_ACTIVE__="
        case unitEnabled = "__CMUX_VPS_UNIT_ENABLED__="
        case linger = "__CMUX_VPS_LINGER__="
        case installedVersions = "__CMUX_VPS_INSTALLED_VERSIONS__="
    }

    /// Desired daemon version whose install path the probe checks.
    public var version: String

    /// Creates a probe for `version`.
    ///
    /// - Parameter version: Daemon version path segment; sanitized before
    ///   shell interpolation (unsafe strings fall back to `dev`).
    public init(version: String) {
        self.version = Self.safePathSegment(version)
    }

    /// The probe shell script. Run it as `sh -c '<script>'` over SSH.
    public func script() -> String {
        let unitName = VPSRemoteLayout.unitName
        return """
        cmux_sha256() {
          if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$1" 2>/dev/null | cut -d " " -f 1
          else
            shasum -a 256 "$1" 2>/dev/null | cut -d " " -f 1
          fi
        }
        cmux_uname_os="$(uname -s)"
        cmux_uname_arch="$(uname -m)"
        cmux_uid="$(id -u)"
        printf '%s%s\\n' '\(Marker.home.rawValue)' "$HOME"
        printf '%s%s\\n' '\(Marker.uid.rawValue)' "$cmux_uid"
        printf '%s%s\\n' '\(Marker.unameOS.rawValue)' "$cmux_uname_os"
        printf '%s%s\\n' '\(Marker.unameArch.rawValue)' "$cmux_uname_arch"
        case "$cmux_uname_os" in
          Linux|linux|LINUX) cmux_go_os=linux ;;
          Darwin|darwin|DARWIN) cmux_go_os=darwin ;;
          FreeBSD|freebsd|FREEBSD) cmux_go_os=freebsd ;;
          *) cmux_go_os=unsupported ;;
        esac
        case "$cmux_uname_arch" in
          x86_64|X86_64|amd64|AMD64) cmux_go_arch=amd64 ;;
          aarch64|AARCH64|arm64|ARM64) cmux_go_arch=arm64 ;;
          armv7l|ARMV7L|armv7|ARMV7) cmux_go_arch=arm ;;
          *) cmux_go_arch=unsupported ;;
        esac
        printf '%s%s\\n' '\(Marker.goOS.rawValue)' "$cmux_go_os"
        printf '%s%s\\n' '\(Marker.goArch.rawValue)' "$cmux_go_arch"
        cmux_distro_id=""
        cmux_distro_pretty=""
        if [ -r /etc/os-release ]; then
          cmux_distro_id="$(. /etc/os-release 2>/dev/null; printf '%s' "${ID:-}")"
          cmux_distro_pretty="$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-}")"
        fi
        printf '%s%s\\n' '\(Marker.distroID.rawValue)' "$cmux_distro_id"
        printf '%s%s\\n' '\(Marker.distroPretty.rawValue)' "$cmux_distro_pretty"
        if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
          printf '%syes\\n' '\(Marker.systemd.rawValue)'
        else
          printf '%sno\\n' '\(Marker.systemd.rawValue)'
        fi
        cmux_binary_path="$HOME/.cmux/bin/cmuxd-remote/\(version)/${cmux_go_os}-${cmux_go_arch}/cmuxd-remote"
        if [ -x "$cmux_binary_path" ]; then
          printf '%syes\\n' '\(Marker.binaryExists.rawValue)'
          printf '%s%s\\n' '\(Marker.binarySHA256.rawValue)' "$(cmux_sha256 "$cmux_binary_path")"
        else
          printf '%sno\\n' '\(Marker.binaryExists.rawValue)'
          printf '%s\\n' '\(Marker.binarySHA256.rawValue)'
        fi
        printf '%s%s\\n' '\(Marker.currentLink.rawValue)' "$(readlink "$HOME/.cmux/vps/current" 2>/dev/null || true)"
        if [ "$cmux_uid" = 0 ]; then
          cmux_unit_path='/etc/systemd/system/\(unitName)'
          cmux_systemctl="systemctl"
        else
          cmux_unit_path="$HOME/.config/systemd/user/\(unitName)"
          cmux_systemctl="env XDG_RUNTIME_DIR=/run/user/$cmux_uid systemctl --user"
        fi
        if [ -f "$cmux_unit_path" ]; then
          printf '%syes\\n' '\(Marker.unitPresent.rawValue)'
          printf '%s%s\\n' '\(Marker.unitSHA256.rawValue)' "$(cmux_sha256 "$cmux_unit_path")"
        else
          printf '%sno\\n' '\(Marker.unitPresent.rawValue)'
          printf '%s\\n' '\(Marker.unitSHA256.rawValue)'
        fi
        printf '%s%s\\n' '\(Marker.unitActive.rawValue)' "$($cmux_systemctl is-active '\(unitName)' 2>/dev/null || true)"
        printf '%s%s\\n' '\(Marker.unitEnabled.rawValue)' "$($cmux_systemctl is-enabled '\(unitName)' 2>/dev/null || true)"
        if [ "$cmux_uid" = 0 ]; then
          printf '%syes\\n' '\(Marker.linger.rawValue)'
        elif [ -e "/var/lib/systemd/linger/$(id -un)" ]; then
          printf '%syes\\n' '\(Marker.linger.rawValue)'
        else
          printf '%sno\\n' '\(Marker.linger.rawValue)'
        fi
        printf '%s%s\\n' '\(Marker.installedVersions.rawValue)' "$(ls "$HOME/.cmux/bin/cmuxd-remote" 2>/dev/null | \(Self.joinWithCommasSnippet) || true)"
        """
    }

    /// Shell fragment turning newline-separated stdin into a comma-joined line
    /// without `tr` (BusyBox class-arg safety, matching the bootstrap probe).
    static let joinWithCommasSnippet =
        #"awk 'NR>1{printf ","} {printf "%s", $0} END{print ""}'"#

    /// Sanitizes a version string for interpolation into remote shell,
    /// mirroring the bootstrap probe's rules (alnum plus `-`, `.`, `_`).
    ///
    /// - Parameter version: Raw version string.
    /// - Returns: `version` when shell-safe, else `"dev"`.
    public static func safePathSegment(_ version: String) -> String {
        guard !version.isEmpty,
              version.count <= 128,
              version != ".",
              version != ".." else {
            return "dev"
        }
        let isSafe = version.utf8.allSatisfy { byte in
            (byte >= 65 && byte <= 90) ||
                (byte >= 97 && byte <= 122) ||
                (byte >= 48 && byte <= 57) ||
                byte == 45 ||
                byte == 46 ||
                byte == 95
        }
        return isSafe ? version : "dev"
    }
}
