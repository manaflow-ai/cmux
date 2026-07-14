import CmuxVPSProvisioning
import Foundation

// Rendering for `cmux vps`: progress events, status lines, and the `--json`
// payload shapes. Command parsing and orchestration live in CMUXCLI+VPS.swift.

extension CMUXCLI {
    static func printVPSEvent(_ event: VPSProvisioningEvent) {
        switch event {
        case .probing(let destination):
            print(String(localized: "cli.vps.event.probing", defaultValue: "Probing \(destination) over SSH..."))
        case .probed(let goOS, let goArch, let distro):
            let platform = distro.isEmpty ? "\(goOS)/\(goArch)" : "\(goOS)/\(goArch), \(distro)"
            print(String(localized: "cli.vps.event.probed", defaultValue: "Detected platform: \(platform)"))
        case .planned(let plan):
            if plan.isAlreadyConverged {
                print(String(localized: "cli.vps.event.converged", defaultValue: "Nothing to change; verifying health."))
            }
        case .acquiringArtifact(let version):
            print(String(localized: "cli.vps.event.acquiring", defaultValue: "Fetching verified cmuxd-remote \(version)..."))
        case .applying(let step):
            if let line = vpsStepDescription(step) {
                print(line)
            }
        case .note(let note):
            switch note {
            case .systemdUnavailable:
                print(String(
                    localized: "cli.vps.event.noSystemd",
                    defaultValue: "Warning: host has no systemd; the daemon is installed but will not auto-start on reboot."
                ))
            case .lingerBestEffort:
                print(String(
                    localized: "cli.vps.event.linger",
                    defaultValue: "Enabling lingering so sessions survive SSH logout (best effort)..."
                ))
            case .lingerUnavailable:
                print(String(
                    localized: "cli.vps.event.lingerUnavailable",
                    defaultValue: "Warning: lingering could not be enabled, so the daemon and its sessions stop when your last SSH connection closes. Run `sudo loginctl enable-linger <user>` on the host, then re-run `cmux vps add`."
                ))
            }
        case .healthChecked(let health):
            print(String(
                localized: "cli.vps.event.health",
                defaultValue: "Health: \(health.state.rawValue) — \(health.detail)"
            ))
        case .completed, .removed:
            break
        }
    }

    static func vpsStepDescription(_ step: VPSProvisioningStep) -> String? {
        switch step {
        case .installBinary(let version, _):
            return String(localized: "cli.vps.step.install", defaultValue: "Installing cmuxd-remote \(version) (checksum-verified)...")
        case .updateCurrentSymlink:
            return String(localized: "cli.vps.step.symlink", defaultValue: "Updating current daemon symlink...")
        case .writeUnitFile(let path, _):
            return String(localized: "cli.vps.step.unit", defaultValue: "Writing systemd unit \(path)...")
        case .daemonReload:
            return String(localized: "cli.vps.step.reload", defaultValue: "Reloading systemd...")
        case .enableUnit:
            return String(localized: "cli.vps.step.enable", defaultValue: "Enabling auto-start on boot...")
        case .restartUnit:
            return String(localized: "cli.vps.step.start", defaultValue: "Starting supervised daemon...")
        case .verifyHealth:
            return String(localized: "cli.vps.step.verify", defaultValue: "Verifying daemon health end to end...")
        case .enableLinger:
            return nil
        }
    }

    static func printVPSStatusLine(entry: VPSRegisteredHost, status: VPSHostStatus) {
        let sessions = status.health.liveSessions
        var line = "\(entry.host.registryKey): \(status.health.state.rawValue)"
        if let version = status.health.daemonVersion {
            line += "  daemon v\(version)"
            if status.health.state == .needsUpgrade {
                line += " (client expects v\(status.desiredVersion))"
            }
        }
        line += "  sessions:\(sessions)"
        if let uptime = status.health.uptimeSeconds {
            line += "  up \(uptime)s"
        }
        print(line)
        print("  \(status.health.detail)")
    }

    static func vpsEntryPayload(_ entry: VPSRegisteredHost) -> [String: Any] {
        [
            "destination": entry.host.destination,
            "port": entry.host.port ?? NSNull(),
            "name": entry.name ?? NSNull(),
            "slot": entry.slot,
            "unit_scope": entry.unitScope?.rawValue ?? NSNull(),
            "installed_version": entry.installedVersion,
            "go_os": entry.goOS,
            "go_arch": entry.goArch,
            "distro_id": entry.distroID,
            "added_at_unix": entry.addedAtUnix,
            "last_seen_at_unix": entry.lastSeenAtUnix ?? NSNull(),
            "mode": "direct",
        ]
    }

    static func vpsOutcomePayload(outcome: VPSProvisionOutcome, entry: VPSRegisteredHost) -> [String: Any] {
        [
            "provisioned": true,
            "already_converged": outcome.alreadyConverged,
            "installed_version": outcome.installedVersion,
            "unit_scope": outcome.unitScope?.rawValue ?? NSNull(),
            "health_state": outcome.health.state.rawValue,
            "health_detail": outcome.health.detail,
            "daemon_version": outcome.health.daemonVersion ?? NSNull(),
            "live_sessions": outcome.health.liveSessions,
            "host": vpsEntryPayload(entry),
        ]
    }

    static func vpsStatusPayload(entry: VPSRegisteredHost, status: VPSHostStatus) -> [String: Any] {
        [
            "destination": entry.host.destination,
            "port": entry.host.port ?? NSNull(),
            "state": status.health.state.rawValue,
            "detail": status.health.detail,
            "daemon_version": status.health.daemonVersion ?? NSNull(),
            "desired_version": status.desiredVersion,
            "live_sessions": status.health.liveSessions,
            "uptime_seconds": status.health.uptimeSeconds ?? NSNull(),
            "unit_active": status.facts.map { $0.unitIsActive as Any } ?? NSNull(),
            "reachable": status.facts != nil,
            "mode": "direct",
        ]
    }
}
