import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextDaemon
import Foundation
import Testing

/// One responder move reaches the focus model once, with where the keyboard landed.
///
/// Live on fleet build 0fcd458acbaa3616eb32c180 (2026-10-31): a press on a Chromium New Tab page
/// moves the keyboard from the editing omnibar to the page's host view. Inside that one
/// `makeFirstResponder`, AppKit ends the edit and passes through the window itself, and the window
/// reported `windowOrNone` twice before `content`: the focus model re-applied its address-bar target in
/// the middle of the move, focused the omnibar again inside AppKit's own change, and the omnibar was
/// left believing it had the keyboard while its field editor was gone.
@MainActor @Suite(.serialized) struct ResponderReportOnceTests {
    private final class Target: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private static func controller() throws -> WindowController {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"responder-report-once","workspace_key":"rr1"}"#.utf8))
        return WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 200, y: 200, width: 900, height: 600))
    }

    private func responderEvents(_ controller: WindowController) -> [String] {
        controller.focus.recent.filter { $0.hasPrefix("responder(") }
    }

    @Test func movingTheKeyboardOutOfAnEditingFieldReportsOnce() throws {
        let controller = try Self.controller()
        defer {
            controller.teardown()
            controller.window?.close()
        }
        let window = try #require(controller.window)
        let content = try #require(window.contentView)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 22))
        let target = Target(frame: NSRect(x: 20, y: 60, width: 200, height: 200))
        content.addSubview(field)
        content.addSubview(target)
        #expect(window.makeFirstResponder(field))
        #expect(field.currentEditor() != nil, "the field is editing")
        let before = responderEvents(controller).count
        #expect(window.makeFirstResponder(target))
        #expect(window.firstResponder === target)
        let reports = Array(responderEvents(controller).dropFirst(before))
        #expect(reports.count == 1, "one move, one report; got \(reports)")
    }
}
