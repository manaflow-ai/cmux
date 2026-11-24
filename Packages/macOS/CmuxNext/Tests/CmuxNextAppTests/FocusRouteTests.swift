import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextDesign
import CmuxNextFocusUI
import Foundation
import Testing

/// The focus route (plans/cmux-next/focus-loss-AUDIT.md, "Focus route"): every keyboard move names
/// its caller and reason, the focus log and `debug.focus_log` show them, and a move the person did
/// not start cannot take the keys from the text input they are typing into.
@MainActor @Suite(.serialized) struct FocusRouteTests {
    private final class Target: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct Harness {
        let controller: WindowController
        let window: ShellWindow
        let log: FocusLog
        let field: NSTextField
        let target: Target
        let directory: URL

        /// A plain key-down the person typed into the window's first responder.
        func type() throws {
            let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                                    windowNumber: window.windowNumber, context: nil, characters: "a",
                                                    charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            log.noteInput(key, in: window)
        }

        func close() {
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func harness(logOn: Bool = true) throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"focus-route","workspace_key":"fr1"}"#.utf8))
        let controller = WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 200, y: 200, width: 900, height: 600))
        let window = try #require(controller.window as? ShellWindow)
        let directory = FileManager.default.temporaryDirectory.appending(path: "focus-route-\(UUID().uuidString)", directoryHint: .isDirectory)
        let log = FocusLog(writer: FocusLogWriter(directory: directory, symbolicate: { $0.map { String($0, radix: 16) } }),
                           context: FocusLog.Context(), enabled: { logOn })
        window.focusLog = log
        let content = try #require(window.contentView)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 22))
        let target = Target(frame: NSRect(x: 20, y: 60, width: 200, height: 200))
        content.addSubview(field)
        content.addSubview(target)
        #expect(FocusRoute(.person, "the test's field").moveKeyboard(in: window, to: field))
        return Harness(controller: controller, window: window, log: log, field: field, target: target, directory: directory)
    }

    @Test func aMoveThePersonDidNotStartLeavesTheFieldTheyTypeIn() throws {
        let h = try Self.harness()
        defer { h.close() }
        try h.type()
        #expect(!FocusRoute(.system, "a background create").moveKeyboard(in: h.window, to: h.target), "refused while typing")
        #expect(h.window.firstResponder === h.field.currentEditor(), "the field keeps the keys")
        let refusal = try #require(h.log.recent().last)
        #expect(refusal.kind == .refused)
        #expect(refusal.route?.contains("a background create") == true, "\(refusal)")
    }

    @Test func aMoveThePersonStartedStillTakesTheKeys() throws {
        let h = try Self.harness()
        defer { h.close() }
        try h.type()
        #expect(FocusRoute(.person, "the person's command").moveKeyboard(in: h.window, to: h.target))
        #expect(h.window.firstResponder === h.target)
    }

    @Test func aSystemMoveTakesTheKeysWhenNobodyTypes() throws {
        let h = try Self.harness()
        defer { h.close() }
        #expect(FocusRoute(.system, "a new tab's input").moveKeyboard(in: h.window, to: h.target))
        #expect(h.window.firstResponder === h.target)
    }

    @Test func everyChangeNamesItsRouteOrUnrouted() throws {
        let h = try Self.harness()
        defer { h.close() }
        FocusRoute(.system, "the composer of a new tab").moveKeyboard(in: h.window, to: h.target)
        let routed = try #require(h.log.recent().last)
        #expect(routed.route?.hasPrefix("system ") == true, "\(routed)")
        #expect(routed.route?.contains("FocusRouteTests.swift:") == true, "the route names its caller: \(routed)")
        #expect(routed.route?.hasSuffix("the composer of a new tab") == true)
        _ = h.window.makeFirstResponder(h.field) // focus-route: the test's unrouted move
        #expect(h.log.recent().last?.route == "unrouted")
    }

    @Test func recentChangesAreKeptWhileTheLogIsOff() async throws {
        let h = try Self.harness(logOn: false)
        defer { h.close() }
        FocusRoute(.system, "a mount").moveKeyboard(in: h.window, to: h.target)
        #expect(h.log.recent().contains { $0.route?.hasSuffix("a mount") == true }, "debug.focus_log has it")
        await h.log.flush()
        #expect(!FileManager.default.fileExists(atPath: h.directory.appending(path: "focus-log.jsonl").path), "no file while off")
    }
}
