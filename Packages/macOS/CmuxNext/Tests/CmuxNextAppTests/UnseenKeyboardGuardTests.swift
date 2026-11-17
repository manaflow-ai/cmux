import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextFocusUI
import CmuxNextPages
import Foundation
import Testing

/// Guardrail G1 (plans/cmux-next/focus-loss-AUDIT.md): no code takes the keyboard from a view the
/// person sees to one they cannot see. Before it, a prewarmed page parked outside the window (or a
/// hidden view) that asked for the keys got them while the window stayed key, and the person's
/// typing went into it.
@MainActor @Suite(.serialized) struct UnseenKeyboardGuardTests {
    private final class Target: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private static func controller() throws -> WindowController {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"unseen-keyboard","workspace_key":"uk1"}"#.utf8))
        return WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 200, y: 200, width: 900, height: 600))
    }

    /// The window with a focused text field and a page parked as `PageOffscreenParking` parks it.
    private static func typing(in controller: WindowController) throws -> (window: NSWindow, field: NSTextField, content: NSView) {
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 22))
        content.addSubview(field)
        #expect(window.makeFirstResponder(field))
        return (window, field, content)
    }

    @Test func aParkedPageCannotTakeTheKeyboardFromATextField() throws {
        let controller = try Self.controller()
        defer { controller.teardown(); controller.window?.close() }
        let (window, field, content) = try Self.typing(in: controller)
        let parking = PageOffscreenParking(frame: PageOffscreenParking.frame(in: content.bounds, size: NSSize(width: 400, height: 300)))
        content.addSubview(parking)
        let page = Target(frame: parking.bounds)
        parking.addSubview(page)
        // The parked page asks for the keys by itself: no key or click, not the focus model.
        #expect(!window.makeFirstResponder(page), "an unseen page never takes the keyboard")
        #expect(field.currentEditor() != nil && window.firstResponder === field.currentEditor(), "the field keeps it")
    }

    @Test func aHiddenViewCannotTakeTheKeyboardFromATextField() throws {
        let controller = try Self.controller()
        defer { controller.teardown(); controller.window?.close() }
        let (window, field, content) = try Self.typing(in: controller)
        let holder = NSView(frame: NSRect(x: 300, y: 20, width: 200, height: 200))
        holder.isHidden = true
        content.addSubview(holder)
        let hidden = Target(frame: holder.bounds)
        holder.addSubview(hidden)
        #expect(!window.makeFirstResponder(hidden))
        #expect(window.firstResponder === field.currentEditor())
    }

    @Test func aShownViewStillTakesTheKeyboard() throws {
        let controller = try Self.controller()
        defer { controller.teardown(); controller.window?.close() }
        let (window, _, content) = try Self.typing(in: controller)
        let shown = Target(frame: NSRect(x: 300, y: 20, width: 200, height: 200))
        content.addSubview(shown)
        #expect(window.makeFirstResponder(shown))
        #expect(window.firstResponder === shown)
    }
}
