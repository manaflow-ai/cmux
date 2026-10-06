import CmuxNextControl
import CmuxNextSettings
import CmuxNextUpdater
import Foundation

// `updates.status`: the updater's state (channel, feed, Sparkle phase,
// automatic-check settings, last probe). `updates.check`: a read-only probe
// of the build's real feed; answers with the typed result (or `pending`
// when the feed is slower than the control deadline), never installs.
extension AppControl {
    func registerUpdateMethods(_ updater: UpdaterService, services appServices: AppServices) {
        service?.router.register([
            .mainActor("updates.status") { _ in .value(Self.json(updater.status, log: updater.log.recent)) },
            // `{build?, check?}`: rolls back to a kept build, or with check
            // only reports whether it would. The daemon's stored formats come
            // with the cmux-tui store.schemas op; until then it refuses.
            .mainActor("updates.rollback") { call in
                let build = call.params["build"]?.stringValue
                if call.params["check"]?.boolValue == true {
                    switch updater.rollbackDecision(to: build, stored: nil) {
                    case .success(let kept): return .value(.object(["allowed": true, "build": .string(kept.build)]))
                    case .failure(let refusal): return .value(.object(["allowed": false, "reason": .string(refusal.message)]))
                    }
                }
                do {
                    let kept = try updater.rollback(to: build, stored: nil, relaunch: UpdaterService.relaunchAfterExit)
                    return .value(.object(["rolled_back_to": .string(kept.build)]))
                } catch let refusal as RollbackRefusal {
                    throw ControlError(code: "rollback_refused", message: refusal.message)
                }
            },
            .mainActor("updates.check") { call in
                let probe = updater.probe()
                // Answer inside the 2 s control deadline. A slower feed leaves
                // the probe running: `pending: true`, then read `updates.status`.
                let answerBy = call.deadline - .milliseconds(150)
                return .followUp {
                    let outcome: (done: Bool, failure: String?)
                    do {
                        outcome = (true, try await ControlDeadline.shared.run(method: call.method, deadline: answerBy) { await probe.value })
                    } catch {
                        outcome = (false, nil)
                    }
                    return await MainActor.run {
                        guard case .object(var fields) = Self.json(updater.status, log: []) else { return .null }
                        fields["pending"] = .bool(!outcome.done)
                        fields["ok"] = outcome.done ? .bool(outcome.failure == nil) : .null
                        if let failure = outcome.failure { fields["error"] = .string(failure) }
                        return .object(fields)
                    }
                }
            },
        ])
        // DEV and NIGHTLY only: a test appcast for every check (signatures
        // still required). `{url: null}` returns to the real feed.
        if updater.identity.track == .nightly || updater.identity.track == .development {
            service?.router.register([
                .mainActor("updates.test_feed") { call in
                    do {
                        try updater.useTestFeed(call.params["url"]?.stringValue, pinned: call.params["pinned"]?.boolValue == true)
                    } catch {
                        throw ControlError.invalidParams(String(describing: error))
                    }
                    return .value(Self.json(updater.status, log: []))
                },
                .mainActor("debug.updater") { [weak services = appServices] call in
                    guard let services else { throw ControlError.invalidParams("debug.updater: the app is shutting down") }
                    return .value(try DebugUpdater.run(call.params, services))
                },
            ])
        }
        #if DEBUG
        service?.router.register([
            .mainActor("debug.update_indicator") { call in
                updater.debugIndicatorPhase = Self.indicatorPhase(call.params)
                return .value(.object(["phase": .string(String(describing: updater.indicatorPhase))]))
            },
        ])
        #endif
    }

    /// `debug.update_indicator {phase, version?, progress?, text?}`: a fixed
    /// rail update circle for screenshots; `phase: "live"` (or none) follows
    /// the updater again.
    static func indicatorPhase(_ params: [String: JSONValue]) -> UpdateIndicatorPhase? {
        switch params["phase"]?.stringValue {
        case "hidden": .hidden
        case "checking": .checking
        case "downloading": .downloading(progress: params["progress"]?.doubleValue)
        case "available": .available(version: params["version"]?.stringValue)
        case "ready": .ready(version: params["version"]?.stringValue)
        case "installing": .installing
        case "note": .note(params["text"]?.stringValue ?? "", isError: params["error"]?.boolValue == true)
        default: nil
        }
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
            "test_feed": status.testFeedURL.map(JSONValue.string) ?? .null,
            "card": status.card.map { card in
                .object(["kind": .string(card.kind), "title": .string(card.presentation.title),
                         "detail": card.presentation.detail.map(JSONValue.string) ?? .null])
            } ?? .null,
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
