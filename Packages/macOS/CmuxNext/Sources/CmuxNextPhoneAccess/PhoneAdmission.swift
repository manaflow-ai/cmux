import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextMobile
import CmuxNextSettings
import CmuxNextWakeups
import Foundation

/// Who may use this Mac from a phone over the Iroh link (`phone.newDevices`): a phone on the
/// allowed list (``MobileHostPairedStore``, Settings > Mobile's one list, as an Iroh entry keyed
/// by its endpoint key) gets in; a new one waits for the person's Allow on this Mac, or, set to
/// Any Phone on My Account, gets in on the account check alone (and is listed, so it can be
/// removed once the setting asks again). An Iroh entry carries no Face ID approval key, so it
/// never reaches hostd or acpmux's approvers.
public final class PhoneAdmission {
    let phones: MobileHostPairedStore
    var mode: PhoneNewDevicesSetting = SessionSettings.newDevicesDefault
    /// A Deny holds for this long, so a phone that keeps reconnecting does not
    /// keep asking.
    static let denialHold: Duration = .seconds(600)
    /// The Allow question's dialog id: only the person answers it (`debug.dialog` refuses it).
    public static let allowDialogIdentifier = "cmux.dialog.phoneAccessAllow"
    private var denied: [String: ContinuousClock.Instant] = [:]
    /// One question per phone, however many connections it opens meanwhile.
    private var asking: [String: Task<Bool, Never>] = [:]
    /// At most this many phones wait on a question at once; another new phone is turned away
    /// unasked (no hold), so a burst of devices cannot stack dialogs.
    static let questionCap = 2
    /// An unanswered question closes as a Deny after this long.
    static let questionTimeout: Duration = .seconds(120)
    /// Shows the question; tests answer it themselves.
    var ask: @MainActor (MobileHostPairRequest) async -> Bool = PhoneAdmission.askOnThisMac
    /// The time a Deny's hold starts from (when it was answered); tests move it.
    var clock: () -> ContinuousClock.Instant = { .now }

    /// - Parameter disconnect: Closes the open sessions of a phone (its endpoint key) taken off
    ///   the list, by Remove in Settings > Mobile or a sign-out.
    init(phones: MobileHostPairedStore, disconnect: @escaping @Sendable (String) async -> Void) {
        self.phones = phones
        phones.observe { [weak self] change in
            let gone = change.removed.filter { $0.transport == .iroh }.map(\.id)
            guard !gone.isEmpty else { return }
            // task-owner: one main-actor hop per removal; disconnect is idempotent
            Task { @MainActor [weak self] in
                for id in gone {
                    self?.denied[id] = nil
                    await disconnect(id)
                }
            }
        }
    }

    /// The signed-in user changed (nil: signed out): their own list, and nothing held over.
    func setUser(_ userID: String?) {
        phones.load(userID: userID)
        denied = [:]
    }

    func decide(_ device: MobileHostPairRequest) async -> Bool {
        let id = device.phoneDeviceID
        // Signed out: no list to put a phone on, so nothing to ask.
        guard phones.current != nil else { return false }
        if phones.trusts(device) { return true }
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
        (try? phones.change { $0.approve(device, at: Date()) }) != nil
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
               defaultValue: "It can see your workspaces and terminals, type into them and, unless you turned it off, start new ones. You can remove it in Settings > Mobile.",
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
