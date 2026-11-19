import AppKit
import CmuxNextActions
import CmuxNextDesign
public import CmuxNextSettings

/// A window-scoped permission guide for the process that actually captures the screen: this app.
/// The same guide serves the visible Share action and the CLI's person-confirmed share request.
@MainActor
struct CmuxRemoteSharingSetup {
    var refresh: () async -> (screen: Bool, control: Bool)
    var requestScreen: () -> Void
    var requestControl: () -> Void
    var enable: () async throws -> Void
    /// Whether the person has said yes to Share This Mac on this Mac (`macScreen.shareWithoutAsking`).
    var consented: @MainActor () -> Bool
    var rememberConsent: @MainActor () -> Void

    init(host: MacScreenHubHost, consent: CmuxRemoteShareConsent = CmuxRemoteShareConsent(given: { false }, remember: {})) {
        refresh = {
            await host.share.refreshPermissions()
            return (host.share.screenRecordingGranted, host.share.accessibilityGranted)
        }
        requestScreen = { host.share.requestScreenRecording() }
        requestControl = { host.share.requestAccessibility() }
        enable = { try await host.setSharing(true, requestPermissions: false) }
        consented = consent.given
        rememberConsent = consent.remember
    }

    /// `remote.confirm {action: share}` for this Mac. With the person's earlier yes and Screen
    /// Recording granted it turns sharing on at once (Accessibility stays optional, as in the
    /// guide); otherwise it shows the guide, whose completion is that yes.
    func ownerRequest(in window: NSWindow?) async throws -> Bool {
        if consented() {
            let permissions = await refresh()
            if permissions.screen, !Task.isCancelled {
                try await enable()
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
                        shared = try await proceed(after: "continue") { spec in
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
                do { return .success(["shared": .bool(try await ownerRequest(in: window))]) }
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
    func proceed(after answer: String, present: (CmuxDialogSpec) async -> String) async throws -> Bool {
        guard answer == "continue", !Task.isCancelled else { return false }
        var permissions = await refresh()
        var screenRequested = false, controlRequested = false, viewOnly = false
        // Every read can revoke either grant. Select the next sheet from both current grants,
        // so losing Screen Recording during the optional control step returns to its guide.
        while !permissions.screen || (!permissions.control && !viewOnly) {
            guard !Task.isCancelled else { return false }
            let needsScreen = !permissions.screen
            let step: Step = needsScreen
                ? (screenRequested ? .screenCheck : .screen)
                : (controlRequested ? .controlCheck : .control)
            let answer = await present(Self.spec(step))
            guard !Task.isCancelled else { return false }
            switch answer {
            case "allow":
                if needsScreen { requestScreen(); screenRequested = true }
                else { requestControl(); controlRequested = true }
            case "check": permissions = await refresh()
            case "view" where !needsScreen:
                viewOnly = true
                permissions = await refresh()
            default: return false
            }
        }
        guard !Task.isCancelled else { return false }
        try await enable()
        // Every path here followed the person's own answer or click: that is the one yes.
        if !consented() { rememberConsent() }
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
                     L.t("macScreen.setup.consent", "Only devices you approve can view or control. A sharing bar shows who is connected and lets you stop with one click.")]
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
public struct CmuxRemoteShareConsent: Sendable {
    public var given: @MainActor @Sendable () -> Bool
    /// Writes the setting as the person: only called after the person's own answer or click.
    public var remember: @MainActor @Sendable () -> Void

    public init(given: @escaping @MainActor @Sendable () -> Bool, remember: @escaping @MainActor @Sendable () -> Void) {
        self.given = given
        self.remember = remember
    }
}

extension CmuxRemoteShareConsent {
    /// `macScreen.shareWithoutAsking` from the app's settings: read from the snapshot (MDM forced
    /// values included) and written as the person once they finish the Share This Mac sheet.
    public static func setting(_ settings: @escaping @MainActor @Sendable () -> SettingsController?) -> Self {
        Self(given: { settings()?.snapshot.macScreen.shareWithoutAsking ?? false },
             remember: {
                 guard let settings = settings(),
                       let descriptor = SettingsSchema.descriptor(for: MacScreenSettings.shareWithoutAskingPath) else { return }
                 // task-owner: one settings write after the person finished the Share This Mac sheet
                 Task { try? await settings.setSetting(descriptor, to: .bool(true), by: .user) }
             })
    }
}
