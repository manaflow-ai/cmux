internal import Foundation

/// Everything `cmux vps` learned about a host from one read-only probe:
/// platform, distro, systemd availability, and the current install state of
/// the daemon binary, `current` symlink, and systemd unit.
public struct VPSHostFacts: Equatable, Sendable {
    /// Absolute remote home directory.
    public var homeDirectory: String
    /// Remote numeric uid (0 means root and selects the system unit scope).
    public var uid: Int
    /// Raw `uname -s` output.
    public var unameOS: String
    /// Raw `uname -m` output.
    public var unameArch: String
    /// Mapped GOOS, or `nil` when the platform is unsupported.
    public var goOS: String?
    /// Mapped GOARCH, or `nil` when the architecture is unsupported.
    public var goArch: String?
    /// `/etc/os-release` `ID` (for example `debian`, `ubuntu`, `fedora`), empty when absent.
    public var distroID: String
    /// `/etc/os-release` `PRETTY_NAME`, empty when absent.
    public var distroPrettyName: String
    /// True when systemd is PID 1 (`/run/systemd/system` exists) and
    /// `systemctl` is on `PATH`.
    public var hasSystemd: Bool
    /// True when the desired-version daemon binary is already executable at
    /// the standard install path.
    public var binaryExists: Bool
    /// SHA-256 of the installed desired-version binary, empty when absent or
    /// when the host has no checksum tool.
    public var binarySHA256: String
    /// Target of the `~/.cmux/vps/current` symlink, empty when absent.
    public var currentSymlinkTarget: String
    /// True when the cmux VPS unit file exists at the scope-appropriate path.
    public var unitFileExists: Bool
    /// SHA-256 of the existing unit file, empty when absent.
    public var unitFileSHA256: String
    /// `systemctl is-active` output for the unit (`active`, `inactive`,
    /// `failed`, empty when systemd/unit is absent).
    public var unitActiveState: String
    /// `systemctl is-enabled` output for the unit (`enabled`, `disabled`,
    /// empty when systemd/unit is absent).
    public var unitEnabledState: String
    /// True when the user lingers (or is root, where lingering is moot).
    public var lingerEnabled: Bool
    /// Daemon versions with install directories on the host.
    public var installedVersions: [String]

    /// Unit scope implied by the probed uid.
    public var unitScope: VPSUnitScope { .forUID(uid) }

    /// True when the unit reports `active`.
    public var unitIsActive: Bool { unitActiveState == "active" }

    /// Memberwise initializer (primarily for tests; production code parses
    /// probe output via ``parse(stdout:)``).
    public init(
        homeDirectory: String,
        uid: Int,
        unameOS: String,
        unameArch: String,
        goOS: String?,
        goArch: String?,
        distroID: String = "",
        distroPrettyName: String = "",
        hasSystemd: Bool,
        binaryExists: Bool = false,
        binarySHA256: String = "",
        currentSymlinkTarget: String = "",
        unitFileExists: Bool = false,
        unitFileSHA256: String = "",
        unitActiveState: String = "",
        unitEnabledState: String = "",
        lingerEnabled: Bool = false,
        installedVersions: [String] = []
    ) {
        self.homeDirectory = homeDirectory
        self.uid = uid
        self.unameOS = unameOS
        self.unameArch = unameArch
        self.goOS = goOS
        self.goArch = goArch
        self.distroID = distroID
        self.distroPrettyName = distroPrettyName
        self.hasSystemd = hasSystemd
        self.binaryExists = binaryExists
        self.binarySHA256 = binarySHA256
        self.currentSymlinkTarget = currentSymlinkTarget
        self.unitFileExists = unitFileExists
        self.unitFileSHA256 = unitFileSHA256
        self.unitActiveState = unitActiveState
        self.unitEnabledState = unitEnabledState
        self.lingerEnabled = lingerEnabled
        self.installedVersions = installedVersions
    }

    /// Parses probe stdout into facts.
    ///
    /// - Parameter stdout: Raw stdout of ``VPSHostProbeScript/script()``.
    /// - Returns: Parsed facts.
    /// - Throws: ``VPSProvisioningError/probeParseFailed(detail:)`` when
    ///   required markers are missing or malformed.
    public static func parse(stdout: String) throws -> VPSHostFacts {
        var values: [VPSHostProbeScript.Marker: String] = [:]
        for rawLine in stdout.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            for marker in VPSHostProbeScript.Marker.allCases where line.hasPrefix(marker.rawValue) {
                values[marker] = String(line.dropFirst(marker.rawValue.count))
                break
            }
        }

        guard let home = values[.home], home.hasPrefix("/") else {
            throw VPSProvisioningError.probeParseFailed(detail: "missing remote home directory")
        }
        guard let uidRaw = values[.uid], let uid = Int(uidRaw), uid >= 0 else {
            throw VPSProvisioningError.probeParseFailed(detail: "missing remote uid")
        }
        guard let unameOS = values[.unameOS], let unameArch = values[.unameArch] else {
            throw VPSProvisioningError.probeParseFailed(detail: "missing uname output")
        }

        let goOS = values[.goOS].flatMap { $0 == "unsupported" || $0.isEmpty ? nil : $0 }
        let goArch = values[.goArch].flatMap { $0 == "unsupported" || $0.isEmpty ? nil : $0 }
        let installedVersions = (values[.installedVersions] ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return VPSHostFacts(
            homeDirectory: home,
            uid: uid,
            unameOS: unameOS,
            unameArch: unameArch,
            goOS: goOS,
            goArch: goArch,
            distroID: values[.distroID] ?? "",
            distroPrettyName: values[.distroPretty] ?? "",
            hasSystemd: values[.systemd] == "yes",
            binaryExists: values[.binaryExists] == "yes",
            binarySHA256: (values[.binarySHA256] ?? "").lowercased(),
            currentSymlinkTarget: values[.currentLink] ?? "",
            unitFileExists: values[.unitPresent] == "yes",
            unitFileSHA256: (values[.unitSHA256] ?? "").lowercased(),
            unitActiveState: values[.unitActive] ?? "",
            unitEnabledState: values[.unitEnabled] ?? "",
            lingerEnabled: values[.linger] == "yes",
            installedVersions: installedVersions
        )
    }
}
