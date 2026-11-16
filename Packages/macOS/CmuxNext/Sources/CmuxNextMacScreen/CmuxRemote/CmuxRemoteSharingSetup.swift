import AppKit
import CmuxNextActions
import CmuxNextDesign

/// A window-scoped permission guide for the process that actually captures the screen: this app.
/// The same guide serves the visible Share action and the CLI's person-confirmed share request.
@MainActor
struct CmuxRemoteSharingSetup {
    var refresh: () async -> (screen: Bool, control: Bool)
    var requestScreen: () -> Void
    var requestControl: () -> Void
    var enable: () async throws -> Void

    init(host: MacScreenHubHost) {
        refresh = {
            await host.share.refreshPermissions()
            return (host.share.screenRecordingGranted, host.share.accessibilityGranted)
        }
        requestScreen = { host.share.requestScreenRecording() }
        requestControl = { host.share.requestAccessibility() }
        enable = { try await host.setSharing(true, requestPermissions: false) }
    }

    /// A native Share click is consent when both grants are ready. Automation still commits its
    /// confirmation sheet on the action's own turn, regardless of the origin it claims.
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

    /// `remote.confirm {action: share}`'s sheet: the overview offers Always Allow beside Continue.
    /// Whether sharing went on, and whether the person chose Always Allow for it. `personPressed` is
    /// read as the overview answers (``overviewAnswer(in:center:personPressed:)``).
    func confirmRequest(in window: NSWindow, center: CmuxDialogCenter = .shared,
                        personPressed: @escaping @MainActor (NSWindow) -> Bool) async throws -> (shared: Bool, always: Bool) {
        let overview = await Self.overviewAnswer(in: window, center: center, personPressed: personPressed)
        return try await afterOverview(overview.button, personPressed: overview.personPressed) { spec in
            await center.present(spec, in: .window(window)).button
        }
    }

    /// SECURITY: the request overview's answer, and whether the person's own press gave it, read in
    /// the answer's own completion: a press answers inside its event's dispatch, which has ended by the
    /// time an awaited answer resumes. Only an Always Allow press reads it. Cancelling dismisses the sheet.
    static func overviewAnswer(in window: NSWindow, center: CmuxDialogCenter,
                               personPressed: @escaping @MainActor (NSWindow) -> Bool) async -> (button: String, personPressed: Bool) {
        let shown = ShownOverview()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                shown.id = center.present(spec(.overview, offerAlways: true), in: .window(window)) { [weak window] answer in
                    var pressed = false
                    if answer.button == "always", let window { pressed = personPressed(window) }
                    continuation.resume(returning: (answer.button, pressed))
                }
                if Task.isCancelled { shown.dismiss(from: center) }
            }
        } onCancel: {
            // task-owner: one hop to the main actor to dismiss the overview this cancelled wait showed
            Task { @MainActor in shown.dismiss(from: center) }
        }
    }

    /// The overview an ``overviewAnswer(in:center:personPressed:)`` showed, for its cancellation.
    @MainActor private final class ShownOverview {
        var id: Int?
        func dismiss(from center: CmuxDialogCenter) {
            if let id { center.dismiss(id) }
        }
    }

    /// The request after its overview: Always Allow goes on as Continue does, and counts as Always
    /// Allow only when the person pressed it and sharing went on; one another process pressed
    /// (computer use, a script) allows this request once.
    func afterOverview(_ button: String, personPressed: Bool,
                       present: (CmuxDialogSpec) async -> String) async throws -> (shared: Bool, always: Bool) {
        let always = button == "always"
        let shared = try await proceed(after: always ? "continue" : button, present: present)
        return (shared, shared && always && personPressed)
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
        return true
    }

    enum Step: String, CaseIterable { case overview, screen, screenCheck, control, controlCheck }

    static func spec(_ step: Step, offerAlways: Bool = false) -> CmuxDialogSpec {
        let title: String, lines: [String], choices: [CmuxDialogButton]
        switch step {
        case .overview:
            title = L.t("macScreen.setup.title", "Share This Mac")
            lines = [L.t("macScreen.setup.source", "Share this Mac’s main display with your devices."),
                     L.t("macScreen.setup.consent", "Only devices you approve can view or control. A sharing bar shows who is connected and lets you stop with one click.")]
            choices = (offerAlways ? [CmuxDialogButton(id: "always", title: CmuxRemoteStrings.alwaysAllow)] : [])
                + [.init(id: "continue", title: L.t("macScreen.setup.continue", "Continue"), role: .default)]
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
                              identifier: "cmux.dialog.screenSharing.setup.\(step.rawValue)")
    }

    private static func permissionButtons(check: Bool) -> [CmuxDialogButton] {
        check
            ? [.init(id: "check", title: L.t("macScreen.setup.check", "Check Again"), role: .default)]
            : [.init(id: "allow", title: L.t("macScreen.setup.allow", "Allow in macOS"), role: .default)]
    }
}
