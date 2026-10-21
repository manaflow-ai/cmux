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
    /// Whose list the holds in `denied` were made on; another user starts with none.
    private var deniedUser: String?
    /// One question per phone, however many connections it opens meanwhile, asked for one user's list.
    private var asking: [String: (user: String, answer: Task<Bool, Never>)] = [:]
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
        deniedUser = phones.current?.userID
        phones.observe { [weak self] change in
            let gone = change.removed.filter { $0.transport == .iroh }.map(\.id)
            let user = change.list?.userID
            // task-owner: one main-actor hop per change; disconnect is idempotent
            Task { @MainActor [weak self] in
                if self?.deniedUser != user { self?.denied = [:] }
                self?.deniedUser = user
                for id in gone {
                    self?.denied[id] = nil
                    await disconnect(id)
                }
            }
        }
    }

    func decide(_ device: MobileHostPairRequest) async -> Bool {
        let id = device.phoneDeviceID
        // Signed out: no list to put a phone on, so nothing to ask. The iPhone host's account
        // says whose list it is (``MobileHostPairedStore/load(userID:)``); this only reads it.
        guard let user = phones.current?.userID else { return false }
        if phones.trusts(device) { return true }
        if mode == .account {
            // Admitted only once listed, so it can always be removed.
            return listed(device, for: user)
        }
        if let at = denied[id], at.duration(to: clock()) < Self.denialHold { return false }
        // A question still open from before a user switch is not this user's: no second dialog, ask later.
        if let open = asking[id], open.user != user { return false }
        guard asking[id] != nil || asking.count < Self.questionCap else { return false }
        // task-owner: the question, shared by this phone's connections; dropped once answered
        let question = asking[id]?.answer ?? Task { await ask(device) }
        asking[id] = (user, question)
        let allowed = await question.value
        // A late waiter must not drop a newer question for this phone.
        if asking[id]?.answer == question { asking[id] = nil }
        // The person answered for the list they were asked on: after a user switch it counts for nobody.
        guard phones.current?.userID == user else { return false }
        guard allowed else {
            denied[id] = clock()
            return false
        }
        // An Allow that cannot be saved lets nothing in: the phone would be unlisted, so it
        // could not be removed.
        return listed(device, for: user)
    }

    private func listed(_ device: MobileHostPairRequest, for user: String) -> Bool {
        (try? phones.change(for: user) { $0.approve(device, at: Date()) }) != nil
    }

    /// The native question, over the key window (or the app when none is open).
    static func askOnThisMac(_ device: MobileHostPairRequest) async -> Bool {
        let scope: CmuxDialogScope = NSApp.keyWindow.map { .window($0) } ?? .app
        NSApp.requestUserAttention(.informationalRequest)
        let center = CmuxDialogCenter.shared
        let timer = DemandTimer(owner: "phone-access-question")
        let answer = await withCheckedContinuation { (done: CheckedContinuation<CmuxDialogAnswer, Never>) in
            let spec = PhoneAccessStrings.allowSpec(name: device.name, key: device.identityKey)
            let id = center.present(spec, in: scope) { done.resume(returning: $0) }
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

    /// The phone's endpoint key, as its Iroh row in Settings > Mobile shows it: a phone can copy
    /// another's name, not its key. Nil (no line) for a key that is not hex.
    static func key(_ endpointKey: String) -> String? {
        guard !endpointKey.isEmpty, endpointKey.count.isMultiple(of: 2), endpointKey.allSatisfy(\.isHexDigit) else { return nil }
        return String(format: String(localized: "phoneAccess.allow.key", defaultValue: "Device key %@", table: "PhoneAccess", bundle: .module),
                      MobileHostPairedDevices.fingerprint(endpointKey))
    }

    static var allow: String { String(localized: "phoneAccess.allow.allow", defaultValue: "Allow", table: "PhoneAccess", bundle: .module) }
    static var deny: String { String(localized: "phoneAccess.allow.deny", defaultValue: "Deny", table: "PhoneAccess", bundle: .module) }

    /// Deny on Escape. Allow has no key: a Return typed as the dialog opens must not let a phone in.
    static func allowSpec(name: String, key endpointKey: String) -> CmuxDialogSpec {
        CmuxDialogSpec(title: title(name: name), lines: [key(endpointKey), message].compactMap { $0 },
                       buttons: [CmuxDialogButton(id: denyID, title: deny, role: .cancel),
                                 CmuxDialogButton(id: allowID, title: allow, role: .normal)],
                       identifier: PhoneAdmission.allowDialogIdentifier)
    }
}
