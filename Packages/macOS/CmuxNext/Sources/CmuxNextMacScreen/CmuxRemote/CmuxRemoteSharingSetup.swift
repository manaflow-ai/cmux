import AppKit
import CmuxNextActions
import CmuxNextDesign
public import CmuxNextSettings
public import Foundation

/// A window-scoped permission guide for the process that actually captures the screen: this app.
/// The same guide serves the visible Share action and the CLI's person-confirmed share request.
@MainActor
struct CmuxRemoteSharingSetup {
    var refresh: () async -> (screen: Bool, control: Bool)
    /// macOS's own request for one grant; returns once macOS's prompt (or System Settings opened
    /// from it) is done with the person, so the guide's next sheet never stacks on macOS's prompt.
    var requestScreen: () async -> Void
    var requestControl: () async -> Void
    var enable: () async throws -> Void
    /// Whether the person has said yes to Share This Mac on this Mac (`macScreen.shareWithoutAsking`, or
    /// this Mac joined to their own account as last read).
    var consented: @MainActor () -> Bool
    /// ``consented``, after reading this Mac's join again: what an owner request asks.
    var consentedNow: @MainActor () async -> Bool
    var rememberConsent: @MainActor () -> Void
    /// The person turned sharing on themselves: an earlier off of theirs no longer stands.
    var forgetDecline: @MainActor () -> Void
    /// Says who turned sharing on with no sheet; tests record it.
    var announce: @MainActor (CmuxRemoteShareCaller?, NSWindow?) -> Void = { caller, window in caller?.announce(in: window) }

    init(host: MacScreenHubHost, consent: CmuxRemoteShareConsent = CmuxRemoteShareConsent(given: { false }, remember: {})) {
        refresh = {
            await host.share.refreshPermissions()
            return (host.share.screenRecordingGranted, host.share.accessibilityGranted)
        }
        requestScreen = { await host.share.requestAndWait(screenRecording: true) }
        requestControl = { await host.share.requestAndWait(screenRecording: false) }
        enable = { try await host.setSharing(true, requestPermissions: false) }
        consented = consent.given
        consentedNow = consent.givenNow
        rememberConsent = consent.remember
        forgetDecline = consent.forgetDecline
    }

    /// `remote.confirm {action: share}` for this Mac. With the person's earlier yes (or this Mac joined to
    /// their own account, read now) and Screen Recording granted it turns sharing on at once
    /// (Accessibility stays optional, as in the guide); otherwise it shows the guide, whose completion is
    /// that yes. Sharing turned on with no sheet says who asked (`caller`), quietly in `window`
    /// (``CmuxRemoteShareCaller``).
    func ownerRequest(in window: NSWindow?, by caller: CmuxRemoteShareCaller?) async throws -> Bool {
        if await consentedNow(), !Task.isCancelled {
            let permissions = await refresh()
            if permissions.screen, !Task.isCancelled {
                try await enable()
                announce(caller, window)
                return true
            }
        }
        guard let window else { return false }
        return try await confirm(in: window)
    }

    /// A native Share click is consent when both grants are ready. Automation commits its
    /// confirmation sheet on the action's own turn, regardless of the origin it claims, unless the
    /// person already said yes on this Mac (`ShareConsent`) and Screen Recording is granted.
    func begin(in window: NSWindow, invocation: ActionInvocation = .init()) -> ActionEffect {
        if invocation.isPersonsOwnRun && ActionRunScope.isPersonsAction() {
            return .applied(result: {
                do {
                    let permissions = await refresh()
                    guard !Task.isCancelled else { return .success(["shared": .bool(false)]) }
                    let shared: Bool
                    if permissions.screen && permissions.control {
                        // Recheck before enabling: a grant can disappear after the first read.
                        shared = try await proceed(after: "continue", remembersYes: false) { spec in
                            await CmuxDialogCenter.shared.present(spec, in: .window(window)).button
                        }
                    } else {
                        shared = try await confirm(in: window)
                    }
                    return .success(["shared": .bool(shared)])
                } catch { return .failure(ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error))) }
            })
        }
        if consented() {
            return .applied(result: {
                do { return .success(["shared": .bool(try await ownerRequest(in: window, by: CmuxRemoteShareCaller(invocation: invocation)))]) }
                catch { return .failure(ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error))) }
            })
        }
        let center = CmuxDialogCenter.shared
        let (answers, sink) = AsyncStream.makeStream(of: CmuxDialogAnswer.self, bufferingPolicy: .bufferingNewest(1))
        let id = center.present(Self.spec(.overview), in: .window(window)) { answer in
            sink.yield(answer)
            sink.finish()
        }
        return .applied(result: {
            var iterator = answers.makeAsyncIterator()
            guard let answer = await iterator.next(), !Task.isCancelled else {
                center.dismiss(id)
                return .success(["shared": .bool(false)])
            }
            do {
                let shared = try await proceed(after: answer.button) { spec in
                    await center.present(spec, in: .window(window)).button
                }
                return .success(["shared": .bool(shared)])
            } catch { return .failure(ActionWorkFailure(log: String(describing: error), reason: PlainErrorText.words(error))) }
        })
    }

    func confirm(in window: NSWindow) async throws -> Bool {
        let center = CmuxDialogCenter.shared
        let answer = await center.present(Self.spec(.overview), in: .window(window))
        return try await proceed(after: answer.button) { spec in
            await center.present(spec, in: .window(window)).button
        }
    }

    /// Each permission step advances only after a fresh TCC read. A declined or closed sheet never
    /// changes the sharing switch. Accessibility is optional; viewing still needs Screen Recording.
    func proceed(after answer: String, remembersYes: Bool = true, present: (CmuxDialogSpec) async -> String) async throws -> Bool {
        guard answer == "continue", !Task.isCancelled else { return false }
        // The guide's steps are Rust's (cmux-rd-ffi `remote.setupStep` / `remote.setupAnswer`): the
        // next sheet from both grants now, and what an answer does. One prompt at a time: no sheet
        // of ours while macOS's prompt is up; every answer ends in a fresh read.
        let read = await refresh()
        var state: [String: Any] = ["screen": read.screen, "control": read.control]
        var next = RdUI.call("remote.setupStep", state) as? [String: Any]
        // Each pass waits on the person's answer to a sheet; it ends when Rust says done (or answers nothing).
        while let current = next, current["done"] as? Bool == false {
            guard !Task.isCancelled, let step = (current["step"] as? String).flatMap(Step.init(rawValue:)) else { return false }
            let answer = await present(Self.spec(step))
            guard !Task.isCancelled, let reply = RdUI.call("remote.setupAnswer", state.merging(["answer": answer]) { $1 }) as? [String: Any],
                  let after = reply["state"] as? [String: Any] else { return false }
            switch reply["action"] as? String {
            case "requestScreen": await requestScreen()
            case "requestControl": await requestControl()
            case "refresh": break
            default: return false
            }
            let permissions = await refresh()
            state = after.merging(["screen": permissions.screen, "control": permissions.control]) { $1 }
            next = RdUI.call("remote.setupStep", state) as? [String: Any]
        }
        // No answer never enables sharing.
        guard !Task.isCancelled, next?["done"] as? Bool == true else { return false }
        try await enable()
        // The overview sheet (its last line names the standing yes) was answered: that is the one yes. A native
        // click with both grants ready shows no sheet and keeps no yes. Either way the person turned sharing
        // on here, so their earlier off no longer holds back the join default.
        if remembersYes, !consented() { rememberConsent() }
        forgetDecline()
        return true
    }

    enum Step: String, CaseIterable { case overview, screen, screenCheck, control, controlCheck }

    nonisolated static func identifier(_ step: Step) -> String { "cmux.dialog.screenSharing.setup.\(step.rawValue)" }

    static func spec(_ step: Step) -> CmuxDialogSpec {
        let title: String, lines: [String], choices: [CmuxDialogButton]
        switch step {
        case .overview:
            title = L.t("macScreen.setup.title", "Share This Mac")
            lines = [L.t("macScreen.setup.source", "Share this Mac’s main display with your devices."),
                     L.t("macScreen.setup.consent", "Only devices you approve can view or control. A sharing bar shows who is connected and lets you stop with one click."),
                     L.t("macScreen.setup.standingYes", "After this, your cmux CLI and agents can turn sharing on without asking. Change it in Settings.")]
            choices = [.init(id: "continue", title: L.t("macScreen.setup.continue", "Continue"), role: .default)]
        case .screen, .screenCheck:
            title = L.t("macScreen.setup.screen.title", "Allow Screen Recording")
            lines = [L.t("macScreen.setup.screen.body", "macOS needs Screen Recording permission for this cmux app to share your display."),
                     L.t("macScreen.setup.screen.settings", "Allow cmux in the macOS permission prompt or System Settings, then return here and check again.")]
            choices = permissionButtons(check: step == .screenCheck)
        case .control, .controlCheck:
            title = L.t("macScreen.setup.control.title", "Allow Accessibility (optional)")
            lines = [L.t("macScreen.setup.control.body", "Accessibility lets a device you approve use the keyboard and pointer. You can share your screen without allowing control.")]
            choices = [.init(id: "view", title: L.t("macScreen.setup.viewOnly", "Continue Without Control"))] + permissionButtons(check: step == .controlCheck)
        }
        return CmuxDialogSpec(title: title, lines: lines, buttons: [.cancel()] + choices,
                              identifier: identifier(step))
    }

    private static func permissionButtons(check: Bool) -> [CmuxDialogButton] {
        check
            ? [.init(id: "check", title: L.t("macScreen.setup.check", "Check Again"), role: .default)]
            : [.init(id: "allow", title: L.t("macScreen.setup.allow", "Allow in macOS"), role: .default)]
    }
}

/// The person's yes to Share This Mac, asked once per Mac and kept: the user-only setting
/// `macScreen.shareWithoutAsking` (Leo, 2026-11-19: "The permissions, just removing them,
/// getting rid of the ceremony"). After it, a share request from the signed-in owner's own
/// CLI, agent or device turns sharing on with no sheet while Screen Recording is granted; who
/// may view or control is still each device's access (`cmux remote-host access`). A fleet Mac
/// gets it forced by its MDM profile (`com.manaflow.cmux`), so nobody there sees the sheet.
///
/// A Mac joined to the signed-in person's own account needs no sheet either: joining is the whole
/// consent (cmuxterm-hq remote-screen-share-zero-touch, Z4). Leo: "who's gonna walk over and click
/// allow on a headless mac mini, or a remote macbook??? stop having that shit."
public struct CmuxRemoteShareConsent: Sendable {
    public var given: @MainActor @Sendable () -> Bool
    /// ``given`` after reading this Mac's join again, as an owner request asks it.
    public var givenNow: @MainActor @Sendable () async -> Bool
    /// Writes the setting as the person: only called after the person's own answer or click.
    public var remember: @MainActor @Sendable () -> Void
    /// Drops the person's recorded off: only called after the person turned sharing on themselves.
    public var forgetDecline: @MainActor @Sendable () -> Void

    public init(given: @escaping @MainActor @Sendable () -> Bool, remember: @escaping @MainActor @Sendable () -> Void,
                givenNow: @escaping @MainActor @Sendable () async -> Bool,
                forgetDecline: @escaping @MainActor @Sendable () -> Void) {
        self.given = given
        self.givenNow = givenNow
        self.remember = remember
        self.forgetDecline = forgetDecline
    }

    /// A yes with no join to read: ``givenNow`` is ``given``.
    public init(given: @escaping @MainActor @Sendable () -> Bool, remember: @escaping @MainActor @Sendable () -> Void) {
        self.init(given: given, remember: remember, givenNow: { given() }, forgetDecline: {})
    }
}

/// This Mac joined to the signed-in person's own account (`JoinStatus.isOwn`): `last` from the last
/// join read, `now` after reading it again. The app fills it from `JoinConsentModel`.
public struct CmuxRemoteOwnJoin: Sendable {
    public var last: @MainActor @Sendable () -> Bool
    public var now: @MainActor @Sendable () async -> Bool

    public init(last: @escaping @MainActor @Sendable () -> Bool, now: @escaping @MainActor @Sendable () async -> Bool) {
        self.last = last
        self.now = now
    }

    public static let none = CmuxRemoteOwnJoin(last: { false }, now: { false })
}

extension CmuxRemoteShareConsent {
    /// This Mac's record of the person's answered Share This Mac sheet: a date in the app's
    /// defaults, outside the settings file (as hang reports keep theirs, HangReportsController).
    nonisolated static let recordKey = "cmux.macScreen.shareWithoutAsking.consentedAt"
    /// This Mac's record of the person's own off: Share This Mac Without Asking turned off after their
    /// yes, or Allow Mac Screen turned off by their own click. Never set by default, so "never set" and
    /// "turned off" read apart; the join default (Z4) stops until the person turns sharing on again.
    nonisolated static let declinedKey = "cmux.macScreen.shareWithoutAsking.declinedAt"

    /// Whether the yes holds. Either the setting is on and this Mac's MDM forces it (a device profile;
    /// a team policy is not the person's yes) or this Mac holds the record of the answered sheet; or
    /// this Mac is joined to the signed-in person's own account (`ownJoin`, Z4: "Joining is the whole
    /// consent"), unless the person turned sharing off here (`declined`) or an administrator forces the
    /// setting off. The user-only policy guards `settings set`, not cmux-next.json, so a `true` an agent
    /// wrote into the file alone never counts (review of #47312); a join can't be written that way,
    /// since its credential is acpmux's and the hub checks it.
    public nonisolated static func holds(settingOn: Bool, managed: ManagedSource?, recorded: Bool,
                                         ownJoin: Bool = false, declined: Bool = false) -> Bool {
        let source: Any = managed.map { $0 == .device ? "device" : "team" } ?? NSNull()
        return RdUI.call("remote.consentHolds", ["settingOn": settingOn, "managed": source, "recorded": recorded,
                                                 "ownJoin": ownJoin, "declined": declined]) as? Bool ?? false
    }

    /// `macScreen.shareWithoutAsking` from the app's settings, with the records in `defaults` and
    /// this Mac's own-account join.
    public static func setting(_ settings: @escaping @MainActor @Sendable () -> SettingsController?,
                               ownJoin: CmuxRemoteOwnJoin = .none, defaults: UserDefaults = .standard) -> Self {
        reading({
            guard let settings = settings() else { return nil }
            return (settings.snapshot.macScreen.shareWithoutAsking,
                    settings.managedKeys[MacScreenSettings.shareWithoutAskingPath.joined(separator: ".")])
        }, ownJoin: ownJoin, defaults: defaults) {
            guard let settings = settings(),
                  let descriptor = SettingsSchema.descriptor(for: MacScreenSettings.shareWithoutAskingPath) else { return false }
            return (try? await settings.setSetting(descriptor, to: .bool(true), by: .user)) != nil
        }
    }

    /// The yes from `setting` (nil before settings load: no yes), the records in `defaults` and `ownJoin`.
    /// `write` writes the setting as the person and says whether it took.
    static func reading(_ setting: @escaping @MainActor @Sendable () -> (on: Bool, managed: ManagedSource?)?,
                        ownJoin: CmuxRemoteOwnJoin, defaults: UserDefaults,
                        write: @escaping @MainActor @Sendable () async -> Bool) -> Self {
        let decide: @MainActor @Sendable (Bool) -> Bool = { joined in
            guard let setting = setting() else { return false }
            return holds(settingOn: setting.on, managed: setting.managed, recorded: defaults.object(forKey: recordKey) is Date,
                         ownJoin: joined, declined: defaults.object(forKey: declinedKey) is Date)
        }
        return Self(given: { decide(ownJoin.last()) }, remember: {
            // task-owner: one settings write after the person answered the Share This Mac sheet; the record is
            // written only once the setting is, so a failed write leaves no record.
            Task {
                guard await write() else { return }
                defaults.set(Date(), forKey: recordKey)
                defaults.removeObject(forKey: declinedKey)
            }
        }, givenNow: {
            if decide(false) { return true }
            // Read the join (an acpmux CLI run) only when it can change the answer.
            guard decide(true) else { return false }
            return decide(await ownJoin.now())
        }, forgetDecline: { defaults.removeObject(forKey: declinedKey) })
    }

    /// Records the person's own off (Allow Mac Screen turned off by their click): the join default no
    /// longer turns sharing on here until they turn it on again. Never called for an agent's or the CLI's off.
    public nonisolated static func recordDecline(defaults: UserDefaults = .standard) {
        defaults.set(Date(), forKey: declinedKey)
    }

    /// Drops the record whenever the setting reads off, from the file, Settings, a reset or an
    /// agent: a later `true` written into the file then needs the sheet again instead of reviving
    /// an old yes (review of #47312, P1). An off after the recorded yes is the person's decline, so the
    /// join default stops too. Called from every settings snapshot change.
    public nonisolated static func forgetUnlessOn(settingOn: Bool, defaults: UserDefaults = .standard) {
        let plan = RdUI.call("remote.forgetUnlessOn", ["settingOn": settingOn, "recorded": defaults.object(forKey: recordKey) is Date]) as? [String: Bool]
        if plan?["recordDecline"] == true { defaults.set(Date(), forKey: declinedKey) }
        if plan?["removeRecord"] == true { defaults.removeObject(forKey: recordKey) }
    }
}
