import AppKit
@testable import CmuxNextDesign
import Testing

/// R96: the dialog view, its focus trap, accessibility, and the R84 overlay
/// host that places it above every page. Windows here are
/// never ordered on screen.
@MainActor
struct CmuxDialogViewTests {
    static let credentials = CmuxDialogSpec(
        title: "Sign in", lines: ["The site asks for a user name and password."], origin: "https://example.com",
        fields: [
            .text("user", initial: "ada", label: "User Name"),
            .text(id: "password", label: "Password", initial: "", placeholder: nil, secure: true),
            .choice(id: "realm", label: nil, options: [CmuxDialogOption(label: "One", value: "1"), CmuxDialogOption(label: "Two", value: "2")], selected: "2"),
            .check(id: "remember", title: "Remember", on: false),
        ],
        buttons: [.cancel(), CmuxDialogButton(id: "sign-in", title: "Sign In", role: .default)],
        identifier: "cmux.dialog.test")

    static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func fieldsReportAndAcceptValues() {
        let view = CmuxDialogView(spec: Self.credentials)
        #expect(view.values == ["user": .text("ada"), "password": .text(""), "realm": .text("2"), "remember": .bool(false)])
        #expect(view.setValue(.text("secret"), for: "password"))
        #expect(view.setValue(.text("1"), for: "realm"))
        #expect(!view.setValue(.text("3"), for: "realm"), "not an option")
        #expect(view.setValue(.bool(true), for: "remember"))
        #expect(view.values["password"] == .text("secret"))
        #expect(view.values["realm"] == .text("1"))
        #expect(view.values["remember"] == .bool(true))
    }

    @Test func tabOrderClosesOnItself() {
        let view = CmuxDialogView(spec: Self.credentials)
        #expect(view.focusables.count == 6, "four fields and two buttons")
        for (index, control) in view.focusables.enumerated() {
            #expect(control.nextKeyView === view.focusables[(index + 1) % view.focusables.count])
        }
    }

    @Test func tabCyclesFocusInsideTheDialogOnly() throws {
        let window = Self.window()
        let center = CmuxDialogCenter()
        let id = center.present(Self.credentials, in: .window(window)) { _ in }
        let view = try #require(center.view(id))
        #expect(view.focusedIndex == 0, "the first text field starts with the keyboard")
        for expected in [1, 2, 3, 4, 5, 0] {
            view.handle(.tab, modifiers: [])
            #expect(view.focusedIndex == expected)
        }
        view.handle(.tab, modifiers: .shift)
        #expect(view.focusedIndex == 5)
        center.dismiss(id)
    }

    @Test func accessibilityNamesTheDialog() {
        let view = CmuxDialogView(spec: Self.credentials)
        #expect(view.isAccessibilityElement())
        #expect(view.accessibilityRole() == .group)
        #expect(view.accessibilitySubrole() == .dialog)
        #expect(view.accessibilityLabel() == "Sign in")
        #expect(view.isAccessibilityModal())
        #expect(view.accessibilityIdentifier() == "cmux.dialog.test")
        #expect(view.accessibilityHelp()?.contains("https://example.com") == true, "VoiceOver hears the origin")
        #expect(view.buttonViews.map { $0.accessibilityLabel() } == ["Cancel", "Sign In"])
    }

    @Test func aTabScopedDialogIsCenteredOnItsTabAndBlocksIt() throws {
        let window = Self.window()
        let root = try #require(window.contentView)
        let left = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 600))
        let right = NSView(frame: NSRect(x: 400, y: 0, width: 400, height: 600))
        root.addSubview(left)
        root.addSubview(right)
        let options = CmuxDialogOverlayHost.options(for: .tab(left))
        let tabRect = left.convert(left.bounds, to: nil)
        #expect(options.kind == .dialog && options.isModal && !options.dimsContent && !options.dismissOnEscape)
        #expect(options.modalRegion == tabRect && options.anchor == tabRect)

        let center = CmuxDialogCenter()
        var answer: CmuxDialogAnswer?
        center.present(Self.credentials, in: .tab(left)) { answer = $0 }
        let host = try #require(WindowOverlayHost.existingHost(for: window))
        #expect(host.presentedHandles.count == 1, "the dialog is on the window's overlay host, above pages")
        #expect(host.acceptsMouse(at: NSPoint(x: 200, y: 300)), "the asking tab is blocked")
        #expect(!host.acceptsMouse(at: NSPoint(x: 600, y: 300)), "the other tab still takes clicks")
        left.setFrameSize(NSSize(width: 300, height: 600))
        let region = try #require(host.presentedHandles.first?.options.modalRegion)
        #expect(region.width == 300, "the blocked region follows a tab resize")
        left.removeFromSuperview()
        #expect(answer == nil, "a tab switch does not end the dialog")
        #expect(host.presentedHandles.isEmpty, "the dialog hides with its tab")
        root.addSubview(left)
        #expect(host.presentedHandles.count == 1, "and shows again with it")
        left.isHidden = true
        #expect(host.presentedHandles.isEmpty, "a hidden tab hides its dialog too")
        left.isHidden = false
        #expect(host.presentedHandles.count == 1)
        center.dismissAll(in: .tab(left))
        #expect(answer?.isDismissal == true)
        #expect(host.presentedHandles.isEmpty)
    }

    @Test func aWindowScopedDialogDimsTheWindowAndLeavesWhenAnswered() throws {
        let window = Self.window()
        let center = CmuxDialogCenter()
        let id = center.present(Self.credentials, in: .window(window)) { _ in }
        let host = try #require(WindowOverlayHost.existingHost(for: window))
        let handle = try #require(host.presentedHandles.first)
        #expect(handle.options.dimsContent && handle.options.isModal)
        #expect(host.acceptsMouse(at: NSPoint(x: 790, y: 10)))
        center.press(id, button: "sign-in")
        #expect(host.presentedHandles.isEmpty)
    }

    /// The app host hides while cmux is inactive: an app-scope dialog (quit
    /// from the Dock with no window) brings the app forward; a window
    /// dialog never does.
    @Test func anAppScopeDialogActivatesTheAppAndAWindowDialogDoesNot() throws {
        var activations = 0
        let center = CmuxDialogCenter(host: CmuxDialogOverlayHost(activate: { activations += 1 }))
        let windowDialog = center.present(Self.credentials, in: .window(Self.window())) { _ in }
        #expect(activations == 0)
        center.dismiss(windowDialog)
        let appDialog = center.present(Self.credentials, in: .app) { _ in }
        #expect(activations == (NSApp.isActive ? 0 : 1))
        center.dismiss(appDialog)
    }

    @Test func closingTheWindowCancelsItsDialog() throws {
        let window = Self.window()
        let center = CmuxDialogCenter()
        var answer: CmuxDialogAnswer?
        center.present(Self.credentials, in: .window(window)) { answer = $0 }
        window.close()
        #expect(answer?.isCancel == true)
        #expect(center.records.isEmpty)
    }

    @Test func returnInTheFormPressesTheDefaultButton() {
        let center = CmuxDialogCenter()
        var answer: CmuxDialogAnswer?
        let id = center.present(Self.credentials, in: .window(Self.window())) { answer = $0 }
        center.setValue(.text("pw"), for: "password", in: id)
        center.key(.return, in: id)
        #expect(answer?.button == "sign-in")
        #expect(answer?.text("password") == "pw")
    }
}
