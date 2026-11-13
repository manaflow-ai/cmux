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

    /// Commit the sheet on the action's own turn; all permission reads and hub work follow it.
    func begin(in window: NSWindow) -> ActionEffect {
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
            } catch { return .failure(ActionWorkFailure(String(describing: error))) }
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
        var requested = false
        while !permissions.screen {
            let answer = await present(Self.spec(requested ? .screenCheck : .screen))
            guard !Task.isCancelled else { return false }
            switch answer {
            case "allow": requestScreen(); requested = true
            case "check": permissions = await refresh()
            default: return false
            }
        }
        requested = false
        while !permissions.control {
            let answer = await present(Self.spec(requested ? .controlCheck : .control))
            guard !Task.isCancelled else { return false }
            if answer == "view" { break }
            switch answer {
            case "allow": requestControl(); requested = true
            case "check": permissions = await refresh()
            default: return false
            }
        }
        guard !Task.isCancelled else { return false }
        try await enable()
        return true
    }

    enum Step: String, CaseIterable { case overview, screen, screenCheck, control, controlCheck }

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
                              identifier: "cmux.dialog.screenSharing.setup.\(step.rawValue)")
    }

    private static func permissionButtons(check: Bool) -> [CmuxDialogButton] {
        check
            ? [.init(id: "check", title: L.t("macScreen.setup.check", "Check Again"), role: .default)]
            : [.init(id: "allow", title: L.t("macScreen.setup.allow", "Allow in macOS"), role: .default)]
    }
}
