import AppKit
import CmuxNextDesign
import CmuxNextMobile
import CmuxNextSettings
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
    /// Shows the question; tests answer it themselves.
    @ObservationIgnored var ask: @MainActor (PhoneDevice) async -> Bool = PhoneAdmission.askOnThisMac

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

    /// Removes `id` from the allowed list; its next connection asks again.
    public func remove(_ id: String) {
        store.remove(id)
        denied[id] = nil
        devices = store.all
    }

    func decide(_ device: PhoneDevice, now: ContinuousClock.Instant = .now) async -> Bool {
        if store.contains(device.id) {
            store.touch(device.id)
            devices = store.all
            return true
        }
        if mode == .account {
            store.allow(device)
            devices = store.all
            return true
        }
        if let at = denied[device.id], at.duration(to: now) < Self.denialHold { return false }
        let question = asking[device.id] ?? Task { await ask(device) }
        asking[device.id] = question
        let allowed = await question.value
        asking[device.id] = nil
        if allowed {
            store.allow(device)
            store.touch(device.id)
            devices = store.all
        } else {
            denied[device.id] = now
        }
        return allowed
    }

    /// The native question, over the key window (or the app when none is open).
    static func askOnThisMac(_ device: PhoneDevice) async -> Bool {
        let scope: CmuxDialogScope = NSApp.keyWindow.map { .window($0) } ?? .app
        NSApp.requestUserAttention(.informationalRequest)
        let answer = await CmuxDialogCenter.shared.present(PhoneAccessStrings.allowSpec(name: device.name), in: scope)
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
