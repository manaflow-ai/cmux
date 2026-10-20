import AppKit
import CmuxNextDesign
import CmuxNextMobile
import CmuxNextSettings
import CmuxNextWakeups
public import CmuxNextSettingsWindow
public import Observation

/// Who may use this Mac from a phone (`phone.newDevices`): a phone on the
/// allowed list gets in; a new one waits for the person's Allow on this Mac,
/// or, set to Any Phone on My Account, gets in on the account check alone
/// (and is listed, so it can be removed once the setting asks again).
@Observable
public final class PhoneAdmission {
    @ObservationIgnored let store: PhoneDeviceStore
    @ObservationIgnored var mode: PhoneNewDevicesSetting = SessionSettings.newDevicesDefault
    /// The allowed phones, for the Settings page's list (observed; the store is not).
    private(set) var devices: [PhoneDevice]
    /// A Deny holds for this long, so a phone that keeps reconnecting does not
    /// keep asking.
    static let denialHold: Duration = .seconds(600)
    @ObservationIgnored private var denied: [String: ContinuousClock.Instant] = [:]
    /// One question per phone, however many connections it opens meanwhile.
    @ObservationIgnored private var asking: [String: Task<Bool, Never>] = [:]
    /// At most this many phones wait on a question at once; another new phone is turned away
    /// unasked (no hold), so a burst of devices cannot stack dialogs.
    static let questionCap = 2
    /// An unanswered question closes as a Deny after this long.
    static let questionTimeout: Duration = .seconds(120)
    /// Shows the question; tests answer it themselves.
    @ObservationIgnored var ask: @MainActor (PhoneDevice) async -> Bool = PhoneAdmission.askOnThisMac
    /// The time a Deny's hold starts from (when it was answered); tests move it.
    @ObservationIgnored var clock: () -> ContinuousClock.Instant = { .now }

    init(store: PhoneDeviceStore) {
        self.store = store
        devices = store.all
    }

    /// The Settings page's Allowed Phones rows: the most recently seen first, each with when it
    /// last connected (observed through `devices`).
    public var rows: [SettingsListRow] {
        devices.sorted { ($0.lastSeenAt ?? $0.approvedAt) > ($1.lastSeenAt ?? $1.approvedAt) }.map { device in
            SettingsListRow(id: device.id, title: device.name,
                            subtitle: (device.lastSeenAt ?? device.approvedAt).formatted(.relative(presentation: .named)), symbol: "iphone")
        }
    }

    /// Removes `id` from the allowed list; its next connection asks again. Throws, keeping the
    /// phone listed and allowed, when the list cannot be saved.
    public func remove(_ id: String) throws {
        defer { devices = store.all }
        try store.remove(id)
        denied[id] = nil
    }

    func decide(_ device: PhoneDevice) async -> Bool {
        if store.contains(device.id) {
            try? store.touch(device.id)  // when it was last seen is not worth refusing a phone over
            devices = store.all
            return true
        }
        if mode == .account {
            // Admitted only once listed, so it can always be removed.
            defer { devices = store.all }
            return (try? store.allow(device)) != nil
        }
        if let at = denied[device.id], at.duration(to: clock()) < Self.denialHold { return false }
        guard asking[device.id] != nil || asking.count < Self.questionCap else { return false }
        // task-owner: the question, shared by this phone's connections; dropped once answered
        let question = asking[device.id] ?? Task { await ask(device) }
        asking[device.id] = question
        let allowed = await question.value
        asking[device.id] = nil
        guard allowed else {
            denied[device.id] = clock()
            return false
        }
        // An Allow that cannot be saved lets nothing in: the phone would be unlisted, so it
        // could not be removed.
        var listed = device
        listed.lastSeenAt = Date()
        defer { devices = store.all }
        return (try? store.allow(listed)) != nil
    }

    /// The native question, over the key window (or the app when none is open).
    static func askOnThisMac(_ device: PhoneDevice) async -> Bool {
        let scope: CmuxDialogScope = NSApp.keyWindow.map { .window($0) } ?? .app
        NSApp.requestUserAttention(.informationalRequest)
        let center = CmuxDialogCenter.shared
        let timer = DemandTimer(owner: "phone-access-question")
        let answer = await withCheckedContinuation { (done: CheckedContinuation<CmuxDialogAnswer, Never>) in
            let id = center.present(PhoneAccessStrings.allowSpec(name: device.name), in: scope) { done.resume(returning: $0) }
            timer.schedule(after: questionTimeout) { @MainActor in _ = center.dismiss(id) }
        }
        timer.cancel()
        return !answer.isDismissal && answer.button == PhoneAccessStrings.allowID
    }
}

/// The Allow question's text (Localizable table "PhoneAccess").
enum PhoneAccessStrings {
    static let allowID = "allow"
    static let denyID = "deny"

    static func title(name: String) -> String {
        String(localized: "phoneAccess.allow.title", defaultValue: "Allow “\(name)” to use this Mac?", table: "PhoneAccess", bundle: .module)
    }

    static var message: String {
        String(localized: "phoneAccess.allow.message",
               defaultValue: "It can see your workspaces and terminals, type into them and, unless you turned it off, start new ones. You can remove it in Settings > Accounts.",
               table: "PhoneAccess", bundle: .module)
    }

    static var allow: String { String(localized: "phoneAccess.allow.allow", defaultValue: "Allow", table: "PhoneAccess", bundle: .module) }
    static var deny: String { String(localized: "phoneAccess.allow.deny", defaultValue: "Deny", table: "PhoneAccess", bundle: .module) }

    /// Deny on Escape. Allow has no key: a Return typed as the dialog opens must not let a phone in.
    static func allowSpec(name: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: title(name: name), lines: [message],
                       buttons: [CmuxDialogButton(id: denyID, title: deny, role: .cancel),
                                 CmuxDialogButton(id: allowID, title: allow, role: .normal)],
                       identifier: "cmux.dialog.phoneAccessAllow")
    }
}
