import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// The coordinator's safety rules around the Passwords page (2026-10-04): automation may not
/// delete a browser profile that holds (or may hold) passwords or passkeys; the reveal sheet's
/// window is left out of screen capture; password export is off until the person turns it on.
@MainActor @Suite(.serialized) struct PasswordsSafetyRulesTests {
    @Test func onlyAPersonDeletesAProfileThatHoldsSecrets() {
        #expect(BrowserProfileSecretsGuard.isPerson(.user) && BrowserProfileSecretsGuard.isPerson(.page))
        for origin in [ActionOrigin.cli, .mcp, .script, .remote] { #expect(!BrowserProfileSecretsGuard.isPerson(origin)) }
        #expect(BrowserProfileSecretsGuard.refusal(PasswordCounts(passwords: 0, passkeys: 0)) == nil)
        #expect(BrowserProfileSecretsGuard.refusal(PasswordCounts(passwords: 3, passkeys: 0)) == PasswordStrings.profileDeleteHoldsSecrets)
        #expect(BrowserProfileSecretsGuard.refusal(PasswordCounts(passwords: 0, passkeys: 1)) == PasswordStrings.profileDeleteHoldsSecrets)
        #expect(BrowserProfileSecretsGuard.refusal(PasswordCounts(passwords: nil, passkeys: 0)) == PasswordStrings.profileDeleteMayHoldSecrets,
                "a count the build cannot read is treated as may hold")
        #expect(BrowserProfileSecretsGuard.refusal(PasswordCounts(passwords: 0, passkeys: nil)) == PasswordStrings.profileDeleteMayHoldSecrets)
    }

    /// A window that keeps the sharing type it is given (a headless worker's window server may
    /// report every window as not shared, which would make the check vacuous).
    final class SharingWindow: NSWindow {
        var stored: NSWindow.SharingType = .readOnly
        override var sharingType: NSWindow.SharingType {
            get { stored }
            set { stored = newValue }
        }
    }

    /// Puts the dialog into a window, as the overlay host does.
    final class WindowHost: CmuxDialogHosting {
        let window: SharingWindow = {
            let window = SharingWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.borderless],
                                       backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = NSView()
            return window
        }()
        private(set) var hidden = 0
        func show(_ dialog: CmuxDialogView, in scope: CmuxDialogScope, scopeGone: @escaping () -> Void) {
            window.contentView?.addSubview(dialog)
        }
        func hide(_ dialog: CmuxDialogView) {
            dialog.removeFromSuperview()
            hidden += 1
        }
    }

    @Test func theRevealSheetIsLeftOutOfScreenCaptureWhileItShows() {
        let inner = WindowHost()
        defer { inner.window.close() }
        let host = CaptureExcludedDialogHost(inner: inner)
        let dialog = CmuxDialogView(spec: CmuxDialogSpec(title: "example.com", buttons: [.ok()]))
        host.show(dialog, in: .app, scopeGone: {})
        #expect(inner.window.stored == .none)
        host.hide(dialog)
        #expect(inner.window.stored == .readOnly, "the window's own sharing type comes back")
        #expect(inner.hidden == 1)
    }

    @Test func passwordExportIsOffByDefaultAndUserOnly() {
        #expect(!PasswordExportSetting.isAllowed(in: .object([:])))
        #expect(PasswordExportSetting.isAllowed(in: ["browser": ["passwords": ["allowExport": true]]]))
        let descriptor = PasswordExportSetting.descriptor
        #expect(SettingsSchema.all.contains { $0.id == descriptor.id })
        #expect(SettingsSchema.agentSettable(descriptor) == false, "agents cannot turn export on")
        #expect(SettingsSchema.agentRefusedKeys[descriptor.id] == .privacy)
    }
}
