import CmuxNextCompat
import CmuxNextDevices
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
            var removeConfirm: Confirm

            enum CodingKeys: String, CodingKey {
                case id, name, platform, fingerprint, fingerprintFull, online, presence, thisDevice, sharesText, access, removeConfirm
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
        let labels = Labels.current
        guard box.configured else {
            return State(available: false, status: .init(text: L.t("devices.status.invalidHubAddress", "The Device Hub Address in Settings › Development is not a valid web address. Fix it, or clear it to use the built-in hub."), tone: "neutral"),
                         signIn: nil, error: nil, labels: labels, thisDevice: nil, others: [], sharing: nil, relays: [], history: [])
        }
        guard let hub else {
            let signIn = canSignIn() ? L.t("devices.signIn", "Sign In to Your Devices") : nil
            let text = signIn == nil ? L.t("devices.status.signedOut", "Sign in to cmux to see your devices.")
                : L.t("devices.status.removed", "This Mac left your devices.")
            return State(available: true, status: .init(text: text, tone: "neutral"), signIn: signIn, error: error, labels: labels,
                         thisDevice: nil, others: [], sharing: nil, relays: [], history: [])
        }
        let me = hub.identity.id
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
            ])
        }
        let relays = hub.relays.sorted { ($0.priority, $0.name) < ($1.priority, $1.name) }.map { relay in
            State.Relay(id: relay.id, name: relay.name, urls: relay.urls, mode: relay.authMode.rawValue, modeText: Self.modeText(relay.authMode),
                        enabled: relay.enabled, priority: relay.priority, hasSecret: hub.relaySecret(relay.id) != nil,
                        checking: checking.contains(relay.id), check: checks[relay.id])
        }
        return State(available: true, status: Self.status(hub), signIn: nil, error: error ?? hubHost.lastError, labels: labels,
                     thisDevice: this, others: hub.otherDevices.map { device(for: $0, hub: hub, me: me) }, sharing: sharing,
                     relays: relays, history: hub.audit.map { Self.historyRow($0, names: names, me: me) })
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
        let presence: String
        if isMe || device.online {
            presence = L.t("devices.online", "Online")
        } else if let seen = device.lastSeenAt {
            presence = String(format: L.t("devices.offlineSeen", "Offline · seen %@"), seen.formatted(.relative(presentation: .named)))
        } else {
            presence = L.t("devices.offline", "Offline")
        }
        let confirm = isMe
            ? State.Device.Confirm(title: L.t("devices.removeThisTitle", "Remove This Mac from your devices?"),
                                   body: L.t("devices.removeThisBody", "This Mac signs out of your devices: its Mac Screen sessions end and your other devices no longer see it. Sign in again to add it back as a new device."),
                                   confirm: L.t("devices.removeConfirm", "Remove"))
            : State.Device.Confirm(title: String(format: L.t("devices.removeTitle", "Remove %@ from your devices?"), device.name),
                                   body: L.t("devices.removeBody", "Its Mac Screen sessions end and it can no longer see or share screens. It comes back as a new device when it signs in again."),
                                   confirm: L.t("devices.removeConfirm", "Remove"))
        return State.Device(
            id: device.id, name: device.name, platform: device.platform == .ios ? L.t("devices.platform.ios", "iPhone") : L.t("devices.platform.mac", "Mac"),
            fingerprint: device.fingerprint.map(DeviceIdentity.displayFingerprint), fingerprintFull: device.fingerprint, online: isMe || device.online, presence: presence,
            thisDevice: isMe, sharesText: device.macScreenShared ? L.t("devices.shares", "Shares Mac Screen") : nil,
            access: isMe ? nil : hub.scope(host: me, viewer: device.id).rawValue, removeConfirm: confirm)
    }

    nonisolated static func modeText(_ mode: RelayAuthMode) -> String {
        switch mode {
        case .sharedSecret: L.t("devices.relay.modeShared", "Shared secret")
        case .static: L.t("devices.relay.modeStatic", "Username and password")
        }
    }

    // MARK: History

    /// One audit entry as the History table shows it (metadata only, as the hub stores it).
    static func historyRow(_ entry: AuditEntry, names: [String: String], me: String) -> State.HistoryRow {
        // A listed device's current name, else the name the entry kept (a removed device), else unknown.
        func name(_ id: String?, kept: String? = nil) -> String {
            guard let id else { return "—" }
            return names[id] ?? kept.flatMap { $0.isEmpty ? nil : $0 } ?? L.t("devices.history.removedDevice", "Removed device")
        }
        let scope: String
        switch entry.scope {
        case "view": scope = SessionScope.view.title
        case "full": scope = SessionScope.full.title
        case let other?: scope = DeviceScope(rawValue: other).map { MacScreenAccess($0).title } ?? other
        case nil: scope = "—"
        }
        return State.HistoryRow(id: entry.id, time: entry.ts.map(Self.timeText) ?? "—",
                                event: entry.event, eventText: eventText(entry.event), tone: eventTone(entry.event),
                                // A device_added/removed entry's device is in deviceId; it shows in the device column.
                                device: entry.deviceId.map { name($0, kept: entry.deviceName) } ?? name(entry.viewerId, kept: entry.viewerName),
                                host: name(entry.hostId, kept: entry.hostName), scope: scope,
                                detail: detailText(entry, viewer: name(entry.viewerId, kept: entry.viewerName),
                                                   host: name(entry.hostId, kept: entry.hostName),
                                                   subject: entry.deviceId.map { name($0, kept: entry.deviceName) } ?? "—"),
                                duration: entry.durationS.map(durationText) ?? "")
    }

    static func eventText(_ event: String) -> String {
        switch event {
        case "shared": L.t("devices.event.shared", "Shared")
        case "unshared": L.t("devices.event.unshared", "Stopped sharing")
        case "requested": L.t("devices.event.requested", "Requested")
        case "approved": L.t("devices.event.approved", "Approved")
        case "denied": L.t("devices.event.denied", "Denied")
        case "started": L.t("devices.event.started", "Started")
        case "ended": L.t("devices.event.ended", "Ended")
        case "permission_changed": L.t("devices.event.permission", "Access changed")
        case "device_added": L.t("devices.event.added", "Device added")
        case "device_removed": L.t("devices.event.removed", "Device removed")
        default: event
        }
    }

    static func eventTone(_ event: String) -> String {
        switch event {
        case "approved", "started", "shared", "device_added": "success"
        case "denied", "device_removed": "danger"
        case "requested", "permission_changed": "attention"
        default: "neutral"
        }
    }

    /// The entry's detail: an access change as "Ask → Full Control", a decision, an end reason.
    static func detailText(_ entry: AuditEntry, viewer: String = "—", host: String = "—", subject: String = "—") -> String {
        // A device joining or leaving names it (whichever id the entry carries).
        if entry.event == "device_added" || entry.event == "device_removed" {
            let name = [subject, viewer, host].first(where: known)
            guard let name else { return entry.event == "device_added" ? "" : L.t("devices.history.someDeviceRemoved", "A device was removed") }
            return entry.event == "device_added" ? String(format: L.t("devices.history.deviceAdded", "%@ was added"), name)
                : String(format: L.t("devices.history.deviceRemoved", "%@ was removed"), name)
        }
        guard let detail = entry.detail, !detail.isEmpty else { return "" }
        switch entry.event {
        case "permission_changed":
            let parts = detail.components(separatedBy: "->")
            guard parts.count == 2 else { return detail }
            let titles = parts.map { part in
                DeviceScope(rawValue: part.trimmingCharacters(in: .whitespaces)).map { MacScreenAccess($0).title } ?? part
            }
            return titles.joined(separator: " → ")
        case "approved", "denied":
            switch detail {
            case "once": return MacScreenApprovalChoice.once.title
            case "always": return L.t("devices.history.always", "Always Allow")
            case "deny": return MacScreenApprovalChoice.deny.title
            default: return detail
            }
        case "ended":
            switch detail {
            case "bye": return L.t("devices.history.bye", "Disconnected")
            default: return endText(MacScreenEndReason(detail), viewer: viewer, host: host)
            }
        default:
            return detail
        }
    }

    /// "Oct 19, 9:12:04 PM": short enough for a narrow History table.
    static func timeText(_ date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    }

    /// Whether a History name is a device's (not "—" or "Removed device").
    static func known(_ name: String) -> Bool {
        name != "—" && name != L.t("devices.history.removedDevice", "Removed device")
    }

    /// An end reason in History, naming the devices (never "this Mac" for another one).
    static func endText(_ reason: MacScreenEndReason, viewer: String, host: String) -> String {
        switch reason {
        case .permissionRevoked, .accessChanged: String(format: L.t("devices.history.revoked", "%@ removed the access"), host)
        case .viewerRemoved: known(viewer) ? String(format: L.t("devices.history.deviceRemoved", "%@ was removed"), viewer)
            : L.t("devices.history.someDeviceRemoved", "A device was removed")
        case .hostRemoved: known(host) ? String(format: L.t("devices.history.deviceRemoved", "%@ was removed"), host)
            : L.t("devices.history.someDeviceRemoved", "A device was removed")
        case .deviceRemoved: L.t("devices.history.someDeviceRemoved", "A device was removed")
        case .sharingOff: String(format: L.t("devices.history.sharingOff", "%@ turned off Mac Screen"), host)
        case .hostStopped: String(format: L.t("devices.history.hostStopped", "%@ stopped sharing"), host)
        case .viewerDisconnected: String(format: L.t("devices.history.viewerDisconnected", "%@ disconnected"), viewer)
        case .signedOut: L.t("devices.history.signedOutOrQuit", "A device signed out or quit cmux")
        case .peerOffline: L.t("devices.history.offline", "A device went offline")
        case .failed: L.t("devices.history.failed", "The stream could not start")
        case .expired: L.t("devices.history.expired", "No answer in time")
        case .approveFailed: L.t("devices.history.approveFailed", "Approved, but the session couldn’t start")
        case .other: L.t("devices.history.other", "Ended")
        }
    }

    /// "22m 27s", "1h 4m", "8s".
    static func durationText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600, minutes = (total % 3600) / 60, rest = total % 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(rest)s" }
        return "\(rest)s"
    }

    // MARK: Gestures

    /// One gesture (`DevicesRun` in ops.ts).
    public nonisolated struct Run: Decodable, Sendable {
        public struct RelayDraft: Decodable, Sendable, Equatable {
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
            case "rename":
                guard let id = run.id, let name = run.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                    return RunResult(error: L.t("devices.error.name", "Enter a name."))
                }
                try await hub.rename(id, name: name)
                if id == hub.identity.id { thisDeviceRenamed(name) }
            case "remove":
                guard let id = run.id else { return RunResult(error: "id") }
                let isMe = id == hub.identity.id
                try await hub.removeDevice(id)
                if isMe { thisDeviceRemoved() }
            case "setAccess":
                guard let id = run.id, let scope = run.scope.flatMap(MacScreenAccess.init(value:)) else {
                    return RunResult(error: "scope")
                }
                try await hub.setPermission(host: hub.identity.id, viewer: id, scope: scope.scope)
            case "setSharing":
                try await hubHost.setSharing(run.on ?? false)
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

    /// What a failed gesture says (never a secret: hub errors carry codes and the server's message).
    static func message(_ error: any Error) -> String {
        guard let hubError = error as? DeviceHubError else { return L.t("devices.error.generic", "That didn’t work. Try again.") }
        switch hubError {
        case .notSignedIn, .notConfigured: return L.t("devices.error.signedOut", "Sign in to cmux first.")
        case .transport: return L.t("devices.error.network", "Couldn’t reach the device hub. Check your connection and try again.")
        default:
            if hubError.code == .deviceRemoved || hubError.code == .notFound {
                return L.t("devices.error.gone", "That device is no longer in your devices.")
            }
            return L.t("devices.error.generic", "That didn’t work. Try again.")
        }
    }

    /// The secret a draft names, or (editing) the one this Mac holds when the fields are left empty.
    static func secret(_ draft: Run.RelayDraft, existing: RelaySecret?) -> RelaySecret? {
        switch draft.mode {
        case RelayAuthMode.sharedSecret.rawValue:
            if let secret = draft.secret, !secret.isEmpty { return .sharedSecret(secret) }
            if case .sharedSecret? = existing { return existing }
            return nil
        default:
            let username = draft.username ?? "", password = draft.password ?? ""
            if !username.isEmpty || !password.isEmpty {
                guard !username.isEmpty, !password.isEmpty else { return nil }
                return .static(username: username, password: password)
            }
            if case .static? = existing { return existing }
            return nil
        }
    }

    /// The draft's TURN URLs, trimmed, empty ones dropped.
    static func urls(_ draft: Run.RelayDraft) -> [String] {
        draft.urls.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func save(_ draft: Run.RelayDraft, hub: DeviceHub) async throws -> RunResult {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let urls = Self.urls(draft)
        guard !name.isEmpty else { return RunResult(error: L.t("devices.error.name", "Enter a name.")) }
        guard !urls.isEmpty, urls.allSatisfy({ $0.hasPrefix("turn:") || $0.hasPrefix("turns:") || $0.hasPrefix("stun:") }) else {
            return RunResult(error: L.t("devices.error.urls", "Enter at least one TURN URL, like turns:turn.example.com:5349."))
        }
        guard let secret = Self.secret(draft, existing: draft.id.flatMap(hub.relaySecret)) else {
            return RunResult(error: draft.mode == RelayAuthMode.sharedSecret.rawValue
                ? L.t("devices.error.secret", "Enter the relay’s shared secret.")
                : L.t("devices.error.credentials", "Enter the relay’s username and password."))
        }
        let relay = try await hub.saveRelay(id: draft.id, name: name, urls: urls, secret: secret, enabled: draft.enabled, priority: draft.priority)
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

    static func checkResult(_ outcome: ICERelayCheck.Outcome) -> State.Check {
        switch outcome {
        case .relayed: .init(tone: "success", text: L.t("devices.relay.checkOK", "The relay works: it gave this Mac a relay address."))
        case .refusedCredentials: .init(tone: "danger", text: L.t("devices.relay.checkRefused", "The relay refused the credentials. Check the shared secret, or the username and password."))
        case .unreachable: .init(tone: "danger", text: L.t("devices.relay.checkUnreachable", "The relay can’t be reached. Check its URLs and that its port is open."))
        case .noRelayCandidate: .init(tone: "danger", text: L.t("devices.relay.checkNone", "No relay address within 10 seconds. Check the URLs, the secret and that the port is open."))
        case .failed: .init(tone: "danger", text: L.t("devices.relay.checkFailed", "The check could not start."))
        }
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
                sharingDetail: L.t("macScreen.home.allowDetail", "Your other devices signed in to this cmux account can ask to see or control this Mac. You approve each device, or choose its access in Settings › Devices."),
                openSettings: L.t("macScreen.home.openSettings", "Open System Settings"),
                allowed: L.t("macScreen.home.granted", "Allowed"),
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
