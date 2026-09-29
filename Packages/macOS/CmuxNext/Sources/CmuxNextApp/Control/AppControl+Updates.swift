import CmuxNextControl
import CmuxNextSettings
import CmuxNextUpdater
import Foundation

// `updates.status`: the updater's state (channel, feed, Sparkle phase,
// automatic-check settings, last probe). `updates.check`: a read-only probe
// of the build's real feed; answers with the typed result, never installs.
extension AppControl {
    func registerUpdateMethods(_ updater: UpdaterService) {
        service?.router.register([
            .mainActor("updates.status") { _ in .value(Self.json(updater.status, log: updater.log.recent)) },
            .mainActor("updates.check") { _ in
                let probe = updater.probe()
                return .followUp {
                    let failure = await probe.value
                    return await MainActor.run {
                        var status = Self.json(updater.status, log: [])
                        if case .object(var fields) = status {
                            fields["ok"] = .bool(failure == nil)
                            if let failure { fields["error"] = .string(failure) }
                            status = .object(fields)
                        }
                        return status
                    }
                }
            },
        ])
    }

    static func json(_ status: UpdaterStatus, log: [String]) -> JSONValue {
        .object([
            "track": .string(status.track.rawValue),
            "bundle_id": status.bundleIdentifier.map(JSONValue.string) ?? .null,
            "version": .string(status.version),
            "build": .string(status.build),
            "minimum_system_version": status.minimumSystemVersion.map { .string($0.description) } ?? .null,
            "system_version": .string(status.system.description),
            "feed_url": .string(status.feedURL),
            "sparkle_enabled": .bool(status.sparkleDisabledReason == nil),
            "sparkle_disabled_reason": status.sparkleDisabledReason.map { .string($0.rawValue) } ?? .null,
            "automatic_checks": .bool(status.automaticChecks),
            "automatic_downloads": .bool(status.automaticDownloads),
            "phase": .string(status.phase.rawValue),
            "detected_version": status.detectedVersion.map(JSONValue.string) ?? .null,
            "probing": .bool(status.probing),
            "last_probe": status.lastProbe.map(json) ?? .null,
            "last_probe_error": status.lastProbeError.map(JSONValue.string) ?? .null,
            "channel_switch_target": status.channelSwitchTarget.map { .string($0.rawValue) } ?? .null,
            "log": .array(log.suffix(20).map(JSONValue.string)),
        ])
    }

    private static func json(_ probe: UpdateProbeResult) -> JSONValue {
        var fields: [String: JSONValue] = [
            "result": .string(probe.outcome.kind),
            "track": .string(probe.track.rawValue),
            "feed_url": .string(probe.feedURL),
            "current_version": .string(probe.currentVersion),
            "current_build": .string(probe.currentBuild),
            "system_version": .string(probe.system.description),
            "item_count": JSONValue(probe.itemCount),
            "checked_at": .string(ISO8601DateFormatter().string(from: probe.checkedAt)),
        ]
        switch probe.outcome {
        case .updateAvailable(let item):
            fields["offered"] = json(item)
        case .upToDate(let latest):
            fields["latest"] = latest.map(json) ?? .null
        case .requiresNewerSystem(let item, let required):
            fields["newer"] = json(item)
            fields["required_system_version"] = .string(required.description)
        }
        return .object(fields)
    }

    private static func json(_ item: AppcastItem) -> JSONValue {
        .object([
            "version": .string(item.version),
            "display_version": .string(item.displayVersion),
            "minimum_system_version": item.minimumSystemVersion.map { .string($0.description) } ?? .null,
            "release_notes": item.releaseNotesURL.map { .string($0.absoluteString) } ?? .null,
        ])
    }
}
