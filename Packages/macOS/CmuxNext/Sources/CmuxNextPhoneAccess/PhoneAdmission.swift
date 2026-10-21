import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextMobile
import CmuxNextSettings
import CmuxNextWakeups
import Foundation
public import CmuxNextSettingsWindow
public import Observation

/// The phones allowed on this Mac over the Iroh link, for the signed-in user: base's
/// ``MobileHostPairedDevices`` in its own 0600 file (`phone-access/paired-devices.json`), apart
/// from the iPhone host's list, so it never reaches acpmux's approvers. Thread-safe, so the host
/// can check a connection without a main-actor hop; a change counts only once it is written.
nonisolated final class AllowedPhones: Sendable {
    private let file: MobileHostPairedDevicesFile
    private let list = Mutex<MobileHostPairedDevices?>(nil)

    init(directory: URL) {
        file = MobileHostPairedDevicesFile(directory: directory.appendingPathComponent("phone-access", isDirectory: true))
    }

    /// The signed-in user's list; nil (no user) allows no phone.
    func load(userID: String?) {
        list.withLock { $0 = userID.map { file.load(userID: $0) } }
    }

    var hasUser: Bool { list.withLock { $0 != nil } }

    var devices: [MobileHostPairedDevice] { list.withLock { $0?.devices ?? [] } }

    func trusts(_ request: MobileHostPairRequest) -> Bool {
        list.withLock { $0?.decision(for: request) == .trusted }
    }

    func contains(_ id: String) -> Bool {
        list.withLock { $0?.devices.contains { $0.id == id } ?? false }
    }

    /// Lists `request`'s phone. Throws, listing nothing, with no user or when the list cannot be saved.
    func approve(_ request: MobileHostPairRequest, at date: Date = Date()) throws {
        try change { $0.approve(request, at: date) }
    }

    /// Takes `id` off the list. A failed write keeps it listed (and allowed) and throws.
    func remove(_ id: String) throws {
        try change { $0.remove(id) }
    }

    private func change(_ edit: (inout MobileHostPairedDevices) -> Void) throws {
        try list.withLock { current in
            guard var next = current else { throw CocoaError(.userCancelled) }
            edit(&next)
            try file.save(next)
            current = next
        }
    }
}

/// Who may use this Mac from a phone (`phone.newDevices`): a phone on the
/// allowed list gets in; a new one waits for the person's Allow on this Mac,
/// or, set to Any Phone on My Account, gets in on the account check alone
/// (and is listed, so it can be removed once the setting asks again).
@Observable
public final class PhoneAdmission {
    @ObservationIgnored let phones: AllowedPhones
    @ObservationIgnored var mode: PhoneNewDevicesSetting = SessionSettings.newDevicesDefault
    /// The allowed phones, for the Settings page's list (observed; the list is not).
    private(set) var devices: [MobileHostPairedDevice] = []
    /// When each phone last connected while this app ran; the list keeps only when it was allowed.
    private(set) var lastSeen: [String: Date] = [:]
    /// A Deny holds for this long, so a phone that keeps reconnecting does not
    /// keep asking.
    static let denialHold: Duration = .seconds(600)
    /// The Allow question's dialog id: only the person answers it (`debug.dialog` refuses it).
    public static let allowDialogIdentifier = "cmux.dialog.phoneAccessAllow"
    @ObservationIgnored private var denied: [String: ContinuousClock.Instant] = [:]
    /// One question per phone, however many connections it opens meanwhile.
    @ObservationIgnored private var asking: [String: Task<Bool, Never>] = [:]
    /// At most this many phones wait on a question at once; another new phone is turned away
    /// unasked (no hold), so a burst of devices cannot stack dialogs.
    static let questionCap = 2
    /// An unanswered question closes as a Deny after this long.
    static let questionTimeout: Duration = .seconds(120)
    /// Shows the question; tests answer it themselves.
    @ObservationIgnored var ask: @MainActor (MobileHostPairRequest) async -> Bool = PhoneAdmission.askOnThisMac
    /// The time a Deny's hold starts from (when it was answered); tests move it.
    @ObservationIgnored var clock: () -> ContinuousClock.Instant = { .now }

    init(phones: AllowedPhones) {
        self.phones = phones
    }

    /// The signed-in user changed (nil: signed out): their own list, and nothing held over.
    func setUser(_ userID: String?) {
        phones.load(userID: userID)
        denied = [:]
        lastSeen = [:]
        devices = phones.devices
    }

    /// The Settings page's Allowed Phones rows: the most recently seen first, each with when it
    /// last connected, or was allowed (observed through `devices`).
    public var rows: [SettingsListRow] {
        let seen = { (device: MobileHostPairedDevice) in self.lastSeen[device.id] ?? device.pairedAt }
        return devices.sorted { seen($0) > seen($1) }.map { device in
            SettingsListRow(id: device.id, title: device.name,
                            subtitle: seen(device).formatted(.relative(presentation: .named)), symbol: "iphone")
        }
    }

    /// Removes `id` from the allowed list; its next connection asks again. Throws, keeping the
    /// phone listed and allowed, when the list cannot be saved.
    public func remove(_ id: String) throws {
        defer { devices = phones.devices }
        try phones.remove(id)
        denied[id] = nil
        lastSeen[id] = nil
    }

    func decide(_ device: MobileHostPairRequest) async -> Bool {
        let id = device.phoneDeviceID
        // Signed out: no list to put a phone on, so nothing to ask.
        guard phones.hasUser else { return false }
        if phones.trusts(device) {
            lastSeen[id] = Date()
            return true
        }
        if mode == .account {
            // Admitted only once listed, so it can always be removed.
            return listed(device)
        }
        if let at = denied[id], at.duration(to: clock()) < Self.denialHold { return false }
        guard asking[id] != nil || asking.count < Self.questionCap else { return false }
        // task-owner: the question, shared by this phone's connections; dropped once answered
        let question = asking[id] ?? Task { await ask(device) }
        asking[id] = question
        let allowed = await question.value
        // A late waiter must not drop a newer question for this phone.
        if asking[id] == question { asking[id] = nil }
        guard allowed else {
            denied[id] = clock()
            return false
        }
        // An Allow that cannot be saved lets nothing in: the phone would be unlisted, so it
        // could not be removed.
        return listed(device)
    }

    private func listed(_ device: MobileHostPairRequest) -> Bool {
        defer { devices = phones.devices }
        guard (try? phones.approve(device)) != nil else { return false }
        lastSeen[device.phoneDeviceID] = Date()
        return true
    }

    /// The native question, over the key window (or the app when none is open).
    static func askOnThisMac(_ device: MobileHostPairRequest) async -> Bool {
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
                       identifier: PhoneAdmission.allowDialogIdentifier)
    }
}
