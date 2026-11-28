import CmuxNextCompat
import CmuxNextDevices
import CmuxNextWakeups
import CmuxScreenKit
import Foundation
public import Observation

/// Settings > Devices (the React Settings page's `devices` card): the state
/// it draws, with every text localized here (`cmux.settings.devices.state`,
/// live through `cmux.settings.devices.changed`), and the gestures it sends
/// (`cmux.settings.devices.run`). This Mac (name, platform, fingerprint),
/// Allow Mac Screen on this Mac with its permissions, the other devices
/// with their access to this Mac, the user's relays (sealed to every device
/// by the hub's sealing; Check Relay gathers a relay candidate), and the
/// audit history. Secrets reach this type only in a gesture and leave it
/// only sealed; the state never carries one.
@MainActor @Observable
public final class MacScreenDevicesSettings {
    /// The last Check Relay result per relay id (`draft` for an unsaved one).
    private var checks: [String: State.Check] = [:]
    private var checking: Set<String> = []
    private var error: String?
    /// Bumped when the hub link's redial hold ends: the card's state reads it and says "Connecting…".
    private var linkRevealed = 0
    /// Holds the hub link's "Connecting…" back (``quietStatus(_:)``); tests give it a manual clock.
    @ObservationIgnored var linkHold = QuietHold(owner: "devices-settings-link", delay: ScreenSession.reconnectNoticeDelay)
    /// The last status shown that was not a redial: it stays while a redial is held.
    @ObservationIgnored private var settledStatus: State.Status?

    @ObservationIgnored let box: MacScreenHubBox
    @ObservationIgnored let hubHost: MacScreenHubHost
    @ObservationIgnored let share: MacScreenShareHost
    /// The device names seen before (History names devices that left the list).
    @ObservationIgnored let store: MacScreenStore
    /// Whether this Mac left the hub (it removed itself) and may sign in again.
    @ObservationIgnored public var canSignIn: @MainActor () -> Bool = { false }
    /// Sign in to the hub again (after this Mac removed itself).
    @ObservationIgnored public var signIn: @MainActor () -> Void = {}
    /// This Mac was removed from the user's devices: the app signs it out of the hub.
    @ObservationIgnored public var thisDeviceRemoved: @MainActor () -> Void = {}
    /// This Mac's name changed (the app keeps it for the next registration).
    @ObservationIgnored public var thisDeviceRenamed: @MainActor (String) -> Void = { _ in }
    /// Opens a verified Mac Screen device from Settings > Devices.
    @ObservationIgnored public var openScreen: @MainActor (String) -> Void = { _ in }
    /// Starts the same guided Share This Mac flow used by the sidebar.
    @ObservationIgnored public var shareThisMac: @MainActor () -> Void = {}
    /// Checks a relay; tests replace it.
    @ObservationIgnored var checkRelay: @Sendable ([ICEServerConfig]) async -> ICERelayCheck.Outcome = { servers in
        await ICERelayCheck(servers: servers).run()
    }
    @ObservationIgnored var now: () -> Date = { Date() }
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var auditWatch: Task<Void, Never>?

    public init(pages: MacScreenPages) {
        box = pages.hubBox
        hubHost = pages.hubHost
        share = pages.host
        store = pages.store
    }

    var hub: DeviceHub? { box.hub }

    // MARK: Watching

    /// A Settings page shows the card: the audit log follows the hub's pushes until `endWatching()`.
    public func beginWatching() {
        watchers += 1
        guard watchers == 1 else { return }
        let box = box
        auditWatch = Task { [weak self] in
            // Every push (and a new hub) may have added audit entries: read them again.
            for await _ in ObservationStream({ box.hub?.pushCount ?? -1 }) {
                await self?.hub?.refreshAudit()
            }
        }
    }

    public func endWatching() {
        watchers = max(0, watchers - 1)
        guard watchers == 0 else { return }
        auditWatch?.cancel()
        auditWatch = nil
    }

    // MARK: State

    /// The card's state (`DevicesState` in webviews/src/pages/settings/ops.ts).
    public nonisolated struct State: Encodable, Equatable, Sendable {
        public struct Status: Encodable, Equatable, Sendable {
            var text: String
            var tone: String
        }

        public struct Device: Encodable, Equatable, Sendable {
            public struct ScreenAction: Encodable, Equatable, Sendable {
                var kind: String
                var title: String
                var disabled: Bool
            }
            public struct Confirm: Encodable, Equatable, Sendable {
                var title: String
                var body: String
                var confirm: String
            }

            var id: String
            var name: String
            var platform: String
            var fingerprint: String?
            /// The whole fingerprint (tooltip and Copy).
            var fingerprintFull: String?
            var online: Bool
            var presence: String
            var thisDevice: Bool
            var sharesText: String?
            var access: String?
            var screenAction: ScreenAction?
            var removeConfirm: Confirm

            enum CodingKeys: String, CodingKey {
                case id, name, platform, fingerprint, fingerprintFull, online, presence, thisDevice, sharesText, access, screenAction, removeConfirm
            }

            /// The page reads null for an absent value, never a missing key.
            public func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(platform, forKey: .platform)
                try c.encode(fingerprint, forKey: .fingerprint)
                try c.encode(fingerprintFull, forKey: .fingerprintFull)
                try c.encode(online, forKey: .online)
                try c.encode(presence, forKey: .presence)
                try c.encode(thisDevice, forKey: .thisDevice)
                try c.encode(sharesText, forKey: .sharesText)
                try c.encode(access, forKey: .access)
                try c.encode(screenAction, forKey: .screenAction)
                try c.encode(removeConfirm, forKey: .removeConfirm)
            }
        }

        public struct Permission: Encodable, Equatable, Sendable {
            var id: String
            var title: String
            var detail: String
            var granted: Bool
        }

        public struct Sharing: Encodable, Equatable, Sendable {
            var on: Bool
            var busy: Bool
            var permissions: [Permission]
            /// The account's "My agents can turn screen sharing and control on my machines" (the hub's).
            var agentsMayShare: Bool
        }

        public struct Check: Encodable, Equatable, Sendable {
            var tone: String
            var text: String
        }

        public struct Relay: Encodable, Equatable, Sendable {
            var id: String
            var name: String
            var urls: [String]
            var mode: String
            var modeText: String
            var enabled: Bool
            var priority: Int
            var hasSecret: Bool
            var checking: Bool
            var check: Check?

            enum CodingKeys: String, CodingKey {
                case id, name, urls, mode, modeText, enabled, priority, hasSecret, checking, check
            }

            public func encode(to encoder: any Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(id, forKey: .id)
                try c.encode(name, forKey: .name)
                try c.encode(urls, forKey: .urls)
                try c.encode(mode, forKey: .mode)
                try c.encode(modeText, forKey: .modeText)
                try c.encode(enabled, forKey: .enabled)
                try c.encode(priority, forKey: .priority)
                try c.encode(hasSecret, forKey: .hasSecret)
                try c.encode(checking, forKey: .checking)
                try c.encode(check, forKey: .check)
            }
        }

        public struct HistoryRow: Encodable, Equatable, Sendable {
            var id: String
            var time: String
            var event: String
            var eventText: String
            var tone: String
            var device: String
            var host: String
            var scope: String
            var detail: String
            var duration: String
        }

        var available: Bool
        var status: Status
        var signIn: String?
        var error: String?
        var labels: Labels
        var thisDevice: Device?
        var others: [Device]
        var sharing: Sharing?
        var relays: [Relay]
        var history: [HistoryRow]

        enum CodingKeys: String, CodingKey {
            case available, status, signIn, error, labels, thisDevice, others, sharing, relays, history
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(available, forKey: .available)
            try c.encode(status, forKey: .status)
            // The page reads null, not a missing key.
            try c.encode(signIn, forKey: .signIn)
            try c.encode(error, forKey: .error)
            try c.encode(labels, forKey: .labels)
            try c.encode(thisDevice, forKey: .thisDevice)
            try c.encode(others, forKey: .others)
            try c.encode(sharing, forKey: .sharing)
            try c.encode(relays, forKey: .relays)
            try c.encode(history, forKey: .history)
        }
    }

    public var state: State {
        var labels = Labels.current
        guard box.configured else {
            return State(available: false, status: .init(text: L.t("devices.status.invalidHubAddress", "The Device Hub Address in Settings › Development is not a valid web address. Fix it, or clear it to use the built-in hub."), tone: "neutral"),
                         signIn: nil, error: nil, labels: labels, thisDevice: nil, others: [], sharing: nil, relays: [], history: [])
        }
        guard let hub else {
            if let message = box.startupMessage {
                return State(available: true, status: .init(text: message, tone: "danger"), signIn: nil,
                             error: message, labels: labels, thisDevice: nil, others: [], sharing: nil, relays: [], history: [])
            }
            if box.restoring || box.connecting {
                // The saved sign-in is still restoring, or signed in with the hub still starting: not signed out.
                return State(available: true, status: .init(text: L.t("macScreen.home.devicesLoading", "Loading your devices…"), tone: "neutral"),
                             signIn: nil, error: nil, labels: labels, thisDevice: nil, others: [], sharing: nil, relays: [], history: [])
            }
            let signIn = canSignIn() ? L.t("devices.signIn", "Sign In to Your Devices") : nil
            let text = signIn == nil ? L.t("devices.status.signedOut", "Sign in to cmux to see your devices.")
                : L.t("devices.status.removed", "This Mac left your devices.")
            return State(available: true, status: .init(text: text, tone: "neutral"), signIn: signIn, error: error, labels: labels,
                         thisDevice: nil, others: [], sharing: nil, relays: [], history: [])
        }
        let me = hub.identity.id
        // Other Devices with no row: "sign in on your other Macs" only after a list read succeeded (ask-6a79af928f).
        switch DeviceDiscovery.of(hub, shown: hub.otherDevices.count) {
        case .list, .noDevices: break
        case .finding: labels.noOthers = L.t("macScreen.home.devicesLoading", "Loading your devices…")
        case let .failed(reason, detail): labels.noOthers = reason.words(detail: detail)
        }
        let names = store.deviceNames.merging(hub.devices.map { ($0.id, $0.name) }) { _, listed in listed }
        let this = hub.thisDevice.map { device(for: $0, hub: hub, me: me) }
        let sharing = hub.thisDevice.map { _ in
            State.Sharing(on: hubHost.isSharing, busy: hubHost.busy, permissions: [
                .init(id: "screenRecording", title: L.t("macScreen.home.screenRecording", "Screen Recording"),
                      detail: L.t("macScreen.home.screenRecordingDetail", "Lets cmux send this screen. macOS may ask you to quit and reopen cmux."),
                      granted: share.screenRecordingGranted),
                .init(id: "accessibility", title: L.t("macScreen.home.accessibility", "Accessibility"),
                      detail: L.t("macScreen.home.accessibilityDetail", "Lets the other Mac click and type here. Without it, it can only watch."),
                      granted: share.accessibilityGranted),
            ], agentsMayShare: hub.agentsMayShare)
        }
        let relays = hub.relays.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }.map { relay in
            State.Relay(id: relay.id, name: relay.name, urls: relay.urls, mode: relay.authMode.rawValue, modeText: Self.modeText(relay.authMode),
                        enabled: relay.enabled, priority: relay.priority, hasSecret: hub.relaySecret(relay.id) != nil,
                        checking: checking.contains(relay.id), check: checks[relay.id])
        }
        return State(available: true, status: quietStatus(hub), signIn: nil, error: error ?? hubHost.lastError, labels: labels,
                     thisDevice: this, others: hub.otherDevices.map { device(for: $0, hub: hub, me: me) }, sharing: sharing,
                     relays: relays, history: Self.historyRows(hub.audit, names: names))
    }

    /// ``status(_:)`` with the hub link's redial held back (Leo, 2026-11-14: "i also want all our
    /// connectivity stuff to shut the f*** up"): the socket redials on its own, so "Connecting…" says
    /// nothing for ``ScreenSession/reconnectNoticeDelay`` (10 s, the sidebar's and every reconnect
    /// label's wait). Under it the last status that was not a redial stays (none on a first connect).
    /// A link that will not redial (removed, replaced, signed out) is never held.
    private func quietStatus(_ hub: DeviceHub) -> State.Status {
        let redialing: Bool = if case .ready = hub.status { Self.redials(hub.connection) } else { false }
        return quiet(Self.status(hub), redialing: redialing)
    }

    /// `status` as the card shows it now: while `redialing` is younger than its hold, the last settled one.
    func quiet(_ status: State.Status, redialing: Bool) -> State.Status {
        _ = linkRevealed
        linkHold.update(redialing) { [weak self] in self?.linkRevealed &+= 1 }
        guard redialing else {
            settledStatus = status
            return status
        }
        return linkHold.held ? settledStatus ?? State.Status(text: "", tone: "neutral") : status
    }

    /// A hub link state that ends without anyone acting: not up yet, coming up, or backing off to redial.
    nonisolated static func redials(_ connection: DeviceHubSocket.State) -> Bool {
        switch connection {
        case .disconnected, .connecting, .reconnecting: true
        case .connected, .replaced, .removed, .signedOut: false
        }
    }

    static func status(_ hub: DeviceHub) -> State.Status {
        switch hub.status {
        case .idle: return .init(text: L.t("devices.status.idle", "Not connected"), tone: "neutral")
        case .starting: return .init(text: L.t("devices.status.starting", "Signing in…"), tone: "attention")
        case let .failed(detail):
            _ = detail
            return .init(text: L.t("devices.status.failed", "Couldn’t reach the device hub. cmux keeps trying."), tone: "danger")
        case .ready: break
        }
        switch hub.connection {
        case .connected: return .init(text: L.t("devices.status.connected", "Connected"), tone: "success")
        case .removed: return .init(text: L.t("devices.status.removed", "This Mac left your devices."), tone: "danger")
        default: return .init(text: L.t("devices.status.connecting", "Connecting…"), tone: "attention")
        }
    }

    private func device(for device: HubDevice, hub: DeviceHub, me: String) -> State.Device {
        let isMe = device.id == me
        let row = MacScreenRules.rdDevices("rd_devices_device_row", [
            "platform": device.platform?.rawValue as Any, "online": device.online, "this_device": isMe, "name": device.name,
            "seen": device.lastSeenAt?.formatted(.relative(presentation: .named)) as Any,
        ], as: Wire.Device.self)
        let confirm = row?.remove ?? [:]
        return State.Device(
            id: device.id, name: device.name, platform: row?.platform.string ?? "",
            fingerprint: device.fingerprint.map(DeviceIdentity.displayFingerprint), fingerprintFull: device.fingerprint, online: isMe || device.online,
            presence: row?.presence.string ?? "", thisDevice: isMe, sharesText: device.macScreenShared ? L.t("devices.shares", "Shares Mac Screen") : nil,
            access: isMe ? nil : hub.scope(host: me, viewer: device.id).rawValue,
            screenAction: row?.screen.map { .init(kind: $0.kind, title: $0.title.string, disabled: $0.disabled) },
            removeConfirm: .init(title: confirm["title"]?.string ?? "", body: confirm["body"]?.string ?? "", confirm: confirm["confirm"]?.string ?? ""))
    }

    /// The `rd_devices_*` answers this card reads: a device row (its words, screen button and Remove
    /// confirmation), a History row, a relay draft's check and a Check Relay result.
    private nonisolated enum Wire {
        struct Screen: Decodable { var kind: String, title: RdWords, disabled: Bool }
        struct Device: Decodable { var platform: RdWords, presence: RdWords, screen: Screen?, remove: [String: RdWords] }
        struct Row: Decodable { var id, event, tone, duration: String; var event_text, device, host, scope, detail: RdWords }
        struct Save: Decodable { var name: String, urls: [String], secret: RelaySecret }
        struct Checked: Decodable { var ok: Save?, error: RdWords? }
        struct Check: Decodable { var tone: String, text: RdWords }
    }

    /// The device row's platform label (`rd_devices_device_row`; a device from before platforms reads as a Mac).
    nonisolated static func platformLabel(_ platform: DevicePlatform?) -> String {
        MacScreenRules.rdDevices("rd_devices_device_row", ["platform": platform?.rawValue as Any], as: Wire.Device.self)?.platform.string ?? ""
    }

    nonisolated static func modeText(_ mode: RelayAuthMode) -> String {
        MacScreenRules.rdDevices("rd_devices_relay_mode", mode.rawValue, as: RdWords.self)?.string ?? mode.rawValue
    }

    // MARK: History

    /// One audit entry as the History table shows it (`rd_devices_history`; Swift adds the time).
    static func historyRow(_ entry: AuditEntry, names: [String: String], me _: String) -> State.HistoryRow {
        historyRows([entry], names: names).first ?? State.HistoryRow(id: entry.id, time: "—", event: entry.event, eventText: entry.event,
                                                                      tone: "neutral", device: "—", host: "—", scope: "—", detail: "", duration: "")
    }

    static func historyRows(_ entries: [AuditEntry], names: [String: String]) -> [State.HistoryRow] {
        guard let encoded = try? JSONEncoder().encode(entries), let list = try? JSONSerialization.jsonObject(with: encoded),
              let rows = MacScreenRules.rdDevices("rd_devices_history", ["entries": list, "names": names], as: [Wire.Row].self) else { return [] }
        return zip(entries, rows).map { entry, row in
            State.HistoryRow(id: row.id, time: entry.ts.map(Self.timeText) ?? "—", event: row.event, eventText: row.event_text.string,
                             tone: row.tone, device: row.device.string, host: row.host.string, scope: row.scope.string,
                             detail: row.detail.string, duration: row.duration)
        }
    }

    /// "Oct 19, 9:12:04 PM": short enough for a narrow History table.
    static func timeText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }

    /// "22m 27s", "1h 4m", "8s" (`rd_devices_duration_text`).
    static func durationText(_ seconds: Double) -> String {
        MacScreenRules.rdDevices("rd_devices_duration_text", ["seconds": seconds], as: String.self) ?? ""
    }

    // MARK: Gestures

    /// One gesture (`DevicesRun` in ops.ts).
    public nonisolated struct Run: Decodable, Sendable {
        public struct RelayDraft: Codable, Sendable, Equatable {
            var id: String?
            var name: String
            var urls: [String]
            var mode: String
            var secret: String?
            var username: String?
            var password: String?
            var enabled: Bool
            var priority: Int
        }

        var action: String
        var id: String?
        var name: String?
        var scope: String?
        var on: Bool?
        var relay: RelayDraft?
    }

    /// `cmux.settings.devices.run`'s answer (`DevicesRunResult`).
    public nonisolated struct RunResult: Encodable, Equatable, Sendable {
        var error: String?
        var text: String?
        var ok: Bool?
    }

    public func run(_ run: Run) async -> RunResult {
        error = nil
        if run.action == "signIn" {
            signIn()
            return RunResult()
        }
        guard let hub else { return RunResult(error: L.t("devices.error.signedOut", "Sign in to cmux first.")) }
        do {
            switch run.action {
            case "refresh":
                await share.refreshPermissions()
                await hub.refreshAll()
                await hub.refreshAudit()
            case "openScreen":
                let id = run.id ?? "", device = hub.devices.first(where: { $0.id == id })
                if let refusal = MacScreenRules.rdDevices("rd_devices_open_screen", [
                    "listed": device != nil, "this_device": id == hub.identity.id, "platform": device?.platform?.rawValue as Any, "online": device?.online ?? false,
                ], as: RdWords?.self) ?? nil { return RunResult(error: refusal.string) }
                openScreen(id)
            case "shareThisMac":
                guard run.id == hub.identity.id else { return RunResult(error: L.t("devices.error.invalidAction", "That action is not available for this device.")) }
                shareThisMac()
            case "rename":
                guard let id = run.id, let name = run.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    return RunResult(error: L.t("devices.error.name", "Enter a name."))
                }
                try await hub.rename(id, name: name)
                if id == hub.identity.id { thisDeviceRenamed(name) }
            case "remove":
                guard let id = run.id else { return RunResult(error: "id") }
                let isMe = id == hub.identity.id
                // Another Mac lists once for all its records (its builds, renewals): Remove takes them all.
                for record in isMe ? [id] : hub.recordIDs(of: id) {
                    try await hub.removeDevice(record)
                }
                if isMe { thisDeviceRemoved() }
            case "setAccess":
                guard let id = run.id, let scope = run.scope.flatMap(MacScreenAccess.init(value:)) else {
                    return RunResult(error: "scope")
                }
                try await hub.setPermission(host: hub.identity.id, viewer: id, scope: scope.scope)
            case "setSharing":
                if run.on == true { shareThisMac() }
                else {
                    // The person's switch in Settings: their off outranks the join default (Z4).
                    CmuxRemoteShareConsent.recordDecline()
                    try await hubHost.setSharing(false)
                }
            case "setAgentsMayShare":
                // The person's click on this switch is the consent; the hub audits it, the notice says it.
                _ = try await CmuxRemoteActionEnvironment.setAgentsMayShare(run.on ?? false, hub: hub, window: nil)
            case "openPermission":
                share.openSettings(screenRecording: run.id == "screenRecording")
            case "saveRelay":
                guard let draft = run.relay else { return RunResult(error: "relay") }
                return try await save(draft, hub: hub)
            case "checkRelay":
                return await check(run, hub: hub)
            case "deleteRelay":
                guard let id = run.id else { return RunResult(error: "id") }
                try await hub.deleteRelay(id)
                checks[id] = nil
            default:
                return RunResult(error: "unknown action")
            }
            await hub.refreshAudit()
            return RunResult(ok: true)
        } catch {
            let text = Self.message(error)
            self.error = text
            return RunResult(error: text)
        }
    }

    /// What a failed gesture says (`rd_devices_error_message`; never a secret: hub errors carry codes).
    static func message(_ error: any Error) -> String {
        let failure: [String: Any] = switch error as? DeviceHubError {
        case .notSignedIn?: ["kind": "not_signed_in"]
        case .notConfigured?: ["kind": "not_configured"]
        case .transport?: ["kind": "transport"]
        case let hubError?: ["kind": "hub", "code": hubError.code?.rawValue as Any]
        case nil: ["kind": "other"]
        }
        return MacScreenRules.rdDevices("rd_devices_error_message", failure, as: RdWords.self)?.string ?? ""
    }

    /// The secret a draft names, or (editing) the one this Mac holds when the fields are left empty (`rd_devices_relay_secret`).
    static func secret(_ draft: Run.RelayDraft, existing: RelaySecret?) -> RelaySecret? {
        relay("rd_devices_relay_secret", draft, existing: existing, as: RelaySecret?.self) ?? nil
    }

    /// The draft's TURN URLs, trimmed, empty ones dropped (`rd_devices_relay_validate` checks them).
    static func urls(_ draft: Run.RelayDraft) -> [String] {
        draft.urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func relay<T: Decodable>(_ operation: String, _ draft: Run.RelayDraft, existing: RelaySecret?, as type: T.Type) -> T? {
        guard let encoded = try? JSONEncoder().encode(draft), let object = try? JSONSerialization.jsonObject(with: encoded) else { return nil }
        let secret = existing.flatMap { try? JSONEncoder().encode($0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        return MacScreenRules.rdDevices(operation, ["draft": object, "existing": secret as Any], as: type)
    }

    private func save(_ draft: Run.RelayDraft, hub: DeviceHub) async throws -> RunResult {
        let checked = Self.relay("rd_devices_relay_validate", draft, existing: draft.id.flatMap(hub.relaySecret), as: Wire.Checked.self)
        guard let save = checked?.ok else { return RunResult(error: checked?.error?.string ?? "relay") }
        let relay = try await hub.saveRelay(id: draft.id, name: save.name, urls: save.urls, secret: save.secret, enabled: draft.enabled, priority: draft.priority)
        checks[relay.id] = nil
        return RunResult(ok: true)
    }

    private func check(_ run: Run, hub: DeviceHub) async -> RunResult {
        let key = run.relay == nil ? (run.id ?? "") : "draft"
        let servers: [ICEServerConfig]
        if let draft = run.relay {
            guard let secret = Self.secret(draft, existing: draft.id.flatMap(hub.relaySecret)) else {
                return RunResult(error: L.t("devices.error.secretToCheck", "Enter the relay’s secret to check it."))
            }
            let relay = HubRelay(id: draft.id ?? "draft", name: draft.name, urls: Self.urls(draft), authMode: secret.authMode)
            servers = [RelaySealing.iceServer(relay, secret: secret, deviceName: hub.thisDevice?.name ?? hub.deviceName,
                                                deviceID: hub.identity.id, now: now()).config]
        } else {
            guard let relay = hub.relays.first(where: { $0.id == run.id }), let secret = hub.relaySecret(relay.id) else {
                return RunResult(error: L.t("devices.error.noSecret", "This Mac can’t open this relay’s secret. Edit the relay and enter it again."))
            }
            servers = [RelaySealing.iceServer(relay, secret: secret, deviceName: hub.thisDevice?.name ?? hub.deviceName,
                                                deviceID: hub.identity.id, now: now()).config]
        }
        checking.insert(key)
        defer { checking.remove(key) }
        let outcome = await checkRelay(servers)
        let result = Self.checkResult(outcome)
        if run.relay == nil { checks[key] = result }
        return RunResult(text: result.text, ok: outcome == .relayed)
    }

    /// Check Relay's words for an outcome (`rd_devices_check_result`).
    static func checkResult(_ outcome: ICERelayCheck.Outcome) -> State.Check {
        let name = switch outcome {
        case .relayed: "relayed"
        case .refusedCredentials: "refused_credentials"
        case .unreachable: "unreachable"
        case .noRelayCandidate: "no_relay_candidate"
        case .failed: "failed"
        }
        let check = MacScreenRules.rdDevices("rd_devices_check_result", ["outcome": name], as: Wire.Check.self)
        return State.Check(tone: check?.tone ?? "danger", text: check?.text.string ?? "")
    }
}

extension MacScreenDevicesSettings {
    /// Every static text of the card, localized here.
    nonisolated struct Labels: Encodable, Equatable, Sendable {
        struct Option: Encodable, Equatable, Sendable {
            var value: String
            var title: String
        }

        struct Columns: Encodable, Equatable, Sendable {
            var time, event, device, host, scope, detail, duration: String
        }

        var thisDeviceSection, thisDeviceBadge, othersSection, noOthers: String
        var fingerprint, rename, renameTitle, nameField, save, cancel, remove: String
        var access: String
        var accessOptions: [Option]
        var sharingSection, sharingToggle, sharingDetail, openSettings, allowed: String
        var agentsToggle, agentsDetail: String
        var relaysSection, relaysEmpty, relaysHelp, addRelay, editRelay, deleteRelay: String
        var deleteRelayTitle, deleteRelayBody, checkRelay, relayOff: String
        var relayName, relayURLs, relayURLsHelp, relayMode: String
        var modeOptions: [Option]
        var relaySecret, relaySecretKeep, relayUsername, relayPassword: String
        var relayEnabled, relayPriority, relayPriorityHelp: String
        var historySection, historyEmpty: String
        var historyColumns: Columns
        var refresh: String
        var copy: String

        static var current: Labels {
            Labels(
                thisDeviceSection: L.t("devices.section.this", "This Mac"),
                thisDeviceBadge: L.t("devices.thisBadge", "This Mac"),
                othersSection: L.t("devices.section.others", "Other Devices"),
                noOthers: L.t("devices.noOthers", "Sign in to cmux on your other Macs to see them here."),
                fingerprint: L.t("devices.fingerprint", "Key fingerprint"),
                rename: L.t("devices.rename", "Rename…"),
                renameTitle: L.t("devices.renameTitle", "Rename Device"),
                nameField: L.t("devices.nameField", "Name"),
                save: L.t("devices.save", "Save"),
                cancel: L.t("devices.cancel", "Cancel"),
                remove: L.t("devices.remove", "Remove…"),
                access: L.t("devices.access", "Mac Screen access to this Mac"),
                accessOptions: MacScreenAccess.all.map { Option(value: $0.value, title: $0.title) },
                sharingSection: L.t("devices.section.sharing", "Mac Screen on This Mac"),
                sharingToggle: L.t("macScreen.home.allowToggle", "Allow Mac Screen on this Mac"),
                sharingDetail: L.t("macScreen.home.shareThisMacOn", "Your devices on this account can connect."),
                openSettings: L.t("macScreen.home.openSettings", "Open System Settings"),
                allowed: L.t("macScreen.home.granted", "Allowed"),
                agentsToggle: CmuxRemoteAgentStrings.settingsToggle,
                agentsDetail: CmuxRemoteAgentStrings.settingsDetail,
                relaysSection: L.t("devices.section.relays", "Relays"),
                relaysEmpty: L.t("devices.relays.empty", "No relays. Sessions connect directly when they can."),
                relaysHelp: L.t("devices.relays.help", "Your own TURN relays for when your Macs can’t reach each other directly. Their secrets are sealed to each of your devices; the device hub never sees them."),
                addRelay: L.t("devices.relays.add", "Add Relay…"),
                editRelay: L.t("devices.relays.edit", "Edit…"),
                deleteRelay: L.t("devices.relays.delete", "Delete"),
                deleteRelayTitle: L.t("devices.relays.deleteTitle", "Delete this relay?"),
                deleteRelayBody: L.t("devices.relays.deleteBody", "Your devices stop using it. Its secret is removed from them."),
                checkRelay: L.t("devices.relays.check", "Check Relay"),
                relayOff: L.t("devices.relays.off", "Off"),
                relayName: L.t("devices.relays.name", "Name"),
                relayURLs: L.t("devices.relays.urls", "TURN URLs"),
                relayURLsHelp: L.t("devices.relays.urlsHelp", "One per line, like turns:turn.example.com:5349."),
                relayMode: L.t("devices.relays.mode", "Authentication"),
                modeOptions: [Option(value: RelayAuthMode.sharedSecret.rawValue, title: modeText(.sharedSecret)),
                              Option(value: RelayAuthMode.static.rawValue, title: modeText(.static))],
                relaySecret: L.t("devices.relays.secret", "Shared secret"),
                relaySecretKeep: L.t("devices.relays.secretKeep", "Leave empty to keep the saved secret."),
                relayUsername: L.t("devices.relays.username", "Username"),
                relayPassword: L.t("devices.relays.password", "Password"),
                relayEnabled: L.t("devices.relays.enabled", "Use this relay"),
                relayPriority: L.t("devices.relays.priority", "Priority"),
                relayPriorityHelp: L.t("devices.relays.priorityHelp", "Lower numbers are tried first."),
                historySection: L.t("devices.section.history", "History"),
                historyEmpty: L.t("devices.history.empty", "No activity yet."),
                historyColumns: Columns(time: L.t("devices.history.time", "Time"), event: L.t("devices.history.event", "Event"),
                                        device: L.t("devices.history.device", "Viewer"), host: L.t("devices.history.host", "Host"),
                                        scope: L.t("devices.history.scope", "Scope"), detail: L.t("devices.history.detail", "Detail"),
                                        duration: L.t("devices.history.duration", "Duration")),
                refresh: L.t("devices.refresh", "Refresh"),
                copy: L.t("devices.copy", "Copy"))
        }
    }
}
