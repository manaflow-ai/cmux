#if DEBUG
// The Chromium host app ships in Debug builds only (embed-cef.sh), and so does its Swift side.
import AppKit
@testable import CmuxNextBrowser
import CmuxNextCompat
import ObjectiveC
import Testing

/// In host mode cmux is the frontmost process, so the page view turns on secure event input
/// while a password field of the page has focus, as Chrome's browser process holds a
/// `ui::ScopedPasswordInputEnabler` (ui/base/cocoa/secure_password_input.mm), and turns it off on blur, hide (which
/// blurs), a window that stops being key, a host that ends and close. The system switch is a recorder: secure input is on
/// while its enables outnumber its disables, as `IsSecureEventInputEnabled` reads HIToolbox's count.
@MainActor @Suite struct ChromiumHostPasswordInputTests {
    /// Counts the system switch's calls.
    nonisolated final class SwitchCalls: Sendable {
        let enables = Atomic<Int>(0)
        let disables = Atomic<Int>(0)

        var system: ChromiumHostPasswordInput.Switch {
            ChromiumHostPasswordInput.Switch(enable: { _ = self.enables.add(1, ordering: .relaxed) },
                                             disable: { _ = self.disables.add(1, ordering: .relaxed) })
        }

        var enableCount: Int { enables.load(ordering: .relaxed) }
        var disableCount: Int { disables.load(ordering: .relaxed) }
        /// `IsSecureEventInputEnabled` for this switch.
        var isOn: Bool { enableCount > disableCount }
    }

    /// Whether the test's window counts as key (a test window never becomes key).
    final class KeyState {
        var isKey = true
    }

    /// Whether the page the owner shows is a cmux page.
    final class ShownPage {
        var isCmuxPage = false
    }

    /// A page view in a window that never shows, with the recorder and the key state as its seams.
    struct Rig {
        let calls = SwitchCalls()
        let key = KeyState()
        let center = NotificationCenter()
        let window: NSWindow
        let view: ChromiumHostPageView

        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
            window.isReleasedWhenClosed = false
            view = ChromiumHostPageView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            view.passwordInput.system = calls.system
            view.passwordInput.windowCenter = center
            let key = key
            view.passwordInput.isKey = { _ in key.isKey }
            window.contentView?.addSubview(view)
        }

        func close() {
            view.removeFromSuperview()
            window.close()
        }
    }

    static let password = ChromiumHostTextInputState(type: .password, selection: 0..<0)
    static let text = ChromiumHostTextInputState(type: .text, selection: 0..<0, text: "abc")

    /// A kTextInputState frame of a focused, empty password field.
    static func passwordFrame() -> ChromiumHostFrame {
        let field = ChromiumHostTextInputTests.stateFrame(caret: [30, 10, 1, 16], textOffset: 0, rects: [], text: "")
        return ChromiumHostFrame(.textInputState, v: [ChromiumHostTextInputState.InputType.password.rawValue, 0, 0, 0, -1, -1],
                                 payload: field.payload)
    }

    @Test func aFocusedPasswordFieldTurnsSecureInputOnAndBlurTurnsItOff() {
        let rig = Rig()
        defer { rig.close() }
        rig.view.applyTextInputState(Self.password)
        #expect(!rig.calls.isOn, "a password field in a page view without focus")
        #expect(rig.window.makeFirstResponder(rig.view))
        #expect(rig.calls.isOn)
        #expect(rig.view.passwordInput.isOn)
        #expect(rig.view.inputContext == nil, "no input method sees a password")

        #expect(rig.window.makeFirstResponder(nil))
        #expect(!rig.calls.isOn)
        #expect(rig.calls.enableCount == 1 && rig.calls.disableCount == 1)
    }

    @Test func secureInputFollowsTheFieldType() {
        let rig = Rig()
        defer { rig.close() }
        #expect(rig.window.makeFirstResponder(rig.view))
        rig.view.applyTextInputState(Self.text)
        #expect(!rig.calls.isOn, "a text field")
        rig.view.applyTextInputState(Self.password)
        #expect(rig.calls.isOn)
        rig.view.applyTextInputState(Self.password)
        #expect(rig.calls.enableCount == 1, "a second push of the same field enables nothing more")
        rig.view.applyTextInputState(Self.text)
        #expect(!rig.calls.isOn)
        rig.view.applyTextInputState(Self.password)
        rig.view.applyTextInputState(ChromiumHostTextInputState())
        #expect(!rig.calls.isOn, "no field focused")
        #expect(rig.calls.enableCount == rig.calls.disableCount)
    }

    /// Hiding the view takes its first responder status (AppKit's `isHidden`): a hidden page is a blurred one, and
    /// showing it again does not give the field back its focus.
    @Test func hidingThePageTurnsSecureInputOff() {
        let rig = Rig()
        defer { rig.close() }
        #expect(rig.window.makeFirstResponder(rig.view))
        rig.view.applyTextInputState(Self.password)
        #expect(rig.calls.isOn)
        rig.view.isHidden = true
        #expect(!rig.calls.isOn)
        rig.view.isHidden = false
        #expect(!rig.calls.isOn)
        #expect(rig.window.makeFirstResponder(rig.view))
        #expect(rig.calls.isOn)
    }

    /// Chrome's `RenderWidgetHostViewMac::SetActive`: another window or app taking the keyboard turns it off, so
    /// a cmux in the background holds no secure input that would block other apps' key taps.
    @Test func aWindowThatStopsBeingKeyTurnsSecureInputOff() {
        let rig = Rig()
        defer { rig.close() }
        #expect(rig.window.makeFirstResponder(rig.view))
        rig.view.applyTextInputState(Self.password)
        #expect(rig.calls.isOn)
        rig.key.isKey = false
        rig.center.post(name: NSWindow.didResignKeyNotification, object: rig.window)
        #expect(!rig.calls.isOn)
        rig.key.isKey = true
        rig.center.post(name: NSWindow.didBecomeKeyNotification, object: rig.window)
        #expect(rig.calls.isOn)
    }

    @Test func closingThePageTurnsSecureInputOff() {
        let rig = Rig()
        defer { rig.window.close() }
        #expect(rig.window.makeFirstResponder(rig.view))
        rig.view.applyTextInputState(Self.password)
        #expect(rig.calls.isOn)
        rig.view.removeFromSuperview()
        #expect(!rig.calls.isOn)
        // Back in a window it is no one's first responder until it is made one again.
        rig.window.contentView?.addSubview(rig.view)
        #expect(!rig.calls.isOn)
        #expect(rig.window.makeFirstResponder(rig.view))
        #expect(rig.calls.isOn)
        rig.view.removeFromSuperview()
        #expect(rig.calls.enableCount == 2 && rig.calls.disableCount == 2)
    }

    /// A focused page moved straight into another window (an addSubview with no removal first) is not that
    /// window's first responder: secure input stays off there until it becomes one, as Chrome reads
    /// `[[self window] firstResponder] == self` (render_widget_host_view_cocoa.mm).
    @Test func aFocusedPageMovedStraightIntoAnotherWindowIsBlurredThere() {
        let rig = Rig()
        let second = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        second.isReleasedWhenClosed = false
        defer {
            rig.close()
            second.close()
        }
        #expect(rig.window.makeFirstResponder(rig.view))
        rig.view.applyTextInputState(Self.password)
        #expect(rig.calls.isOn)

        second.contentView?.addSubview(rig.view)
        #expect(rig.view.window === second)
        #expect(second.firstResponder !== rig.view)
        #expect(!rig.calls.isOn, "keyboard focus is elsewhere in the new window")

        #expect(second.makeFirstResponder(rig.view))
        #expect(rig.calls.isOn)
        #expect(rig.calls.enableCount == 2 && rig.calls.disableCount == 1)
    }

    /// The enabler is scoped: releasing what holds it (the page view's release too) disables once.
    @Test func releasingTheHolderDisablesOnce() {
        let calls = SwitchCalls()
        do {
            var input = ChromiumHostPasswordInput()
            input.system = calls.system
            input.turn(true)
            input.turn(true)
            #expect(input.isOn)
            #expect(calls.enableCount == 1)
        }
        #expect(calls.enableCount == 1 && calls.disableCount == 1)
    }

    /// No macOS 14 caret bubble over a cmux page on the host page view, the text input client cmux implements
    /// itself; a web page keeps the system's placement, as on Chromium's own view (`ChromiumPageTextAccessory`).
    /// AppKit asks through the Objective-C selector, so the answer is read there.
    @Test func aCmuxPageShowsNoCaretAccessory() throws {
        let view = ChromiumHostPageView(frame: .zero)
        #expect(try Self.accessoryPlacement(of: view) == .unspecified, "no owner: a web page")
        let shown = ShownPage()
        view.showsCmuxPage = { shown.isCmuxPage }
        #expect(try Self.accessoryPlacement(of: view) == .unspecified)
        shown.isCmuxPage = true
        #expect(try Self.accessoryPlacement(of: view) == .invisible)
    }

    /// The caret accessory placement AppKit reads from `view` (`-preferredTextAccessoryPlacement`).
    static func accessoryPlacement(of view: ChromiumHostPageView) throws -> NSTextCursorAccessoryPlacement? {
        typealias Getter = @convention(c) (AnyObject, Selector) -> Int
        let selector = ChromiumPageTextAccessory.selector
        try #require(view.responds(to: selector))
        let imp = try #require(class_getMethodImplementation(ChromiumHostPageView.self, selector))
        return NSTextCursorAccessoryPlacement(rawValue: unsafeBitCast(imp, to: Getter.self)(view, selector))
    }
}

extension ChromiumHostSessionTests {
    /// The host ends with a password field focused: its field went with it, and so does secure input.
    @Test(.timeLimit(.minutes(1))) func aHostThatEndsTurnsSecureInputOff() async throws {
        _ = NSApplication.shared
        let calls = ChromiumHostPasswordInputTests.SwitchCalls()
        let launcher = FakeLauncher()
        let session = ChromiumHostSession(configuration: Self.configuration, launcher: launcher)
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300), styleMask: .borderless,
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer {
            session.view.removeFromSuperview()
            window.close()
            session.close()
        }
        session.view.passwordInput.system = calls.system
        session.view.passwordInput.isKey = { _ in true }
        session.view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        window.contentView?.addSubview(session.view)
        #expect(window.makeFirstResponder(session.view))
        session.open("https://a.example/")
        let first = try await nextLaunch(launcher)
        answer(first, context: 5, address: "https://a.example/")
        first.wire.send(ChromiumHostPasswordInputTests.passwordFrame())
        first.wire.send(ChromiumHostFrame(.title, payload: Array("pushed".utf8)))
        try await until("the push is applied") { session.title == "pushed" }
        #expect(session.view.textInput.state.type == .password)
        #expect(calls.isOn)
        #expect((session.report["password_input"] as? Bool) == true)

        launcher.end(first, ChromiumHostExit(signal: SIGKILL, status: nil))
        _ = try await nextLaunch(launcher)
        #expect(!calls.isOn)
        #expect(calls.enableCount == 1 && calls.disableCount == 1)
        #expect((session.report["password_input"] as? Bool) == false)
    }
}
#endif
