import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBridge
import CmuxNextDaemon
import CmuxNextFocusUI
import Foundation
import Testing

/// The focus log (`tunable.diagnostics.focusLog`) writes every first responder change of a cmux
/// window with its cause, including the ones AppKit makes when the focused view leaves the
/// window, and flags a move that took the keyboard from a text input with no key or click.
@MainActor @Suite(.serialized) struct FocusLogTests {
    private final class Target: NSView {
        override var acceptsFirstResponder: Bool { true }
    }

    private struct Harness {
        let controller: WindowController
        let window: NSWindow
        let log: FocusLog
        let directory: URL

        func lines() async throws -> [FocusLogEntry] {
            await log.flush()
            let url = directory.appending(path: "focus-log.jsonl")
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let text = try String(contentsOf: url, encoding: .utf8)
            return try text.split(separator: "\n").map { try JSONDecoder().decode(FocusLogEntry.self, from: Data($0.utf8)) }
        }

        func close() {
            controller.teardown()
            controller.window?.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func harness(enabled: Bool = true) throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        let record = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"id":"focus-log","workspace_key":"fl1"}"#.utf8))
        let controller = WindowController(state: WindowState(record: record), services: services, frame: NSRect(x: 200, y: 200, width: 900, height: 600))
        let window = try #require(controller.window as? ShellWindow)
        let directory = FileManager.default.temporaryDirectory.appending(path: "focus-log-\(UUID().uuidString)", directoryHint: .isDirectory)
        let log = FocusLog(writer: FocusLogWriter(directory: directory, symbolicate: { $0.map { String($0, radix: 16) } }),
                           context: FocusLog.Context(classify: { responder, window in
                               (window.windowController as? WindowController).map { String(describing: FocusResponderClassifier.classify(responder, in: $0)) }
                           }), enabled: { enabled })
        window.focusLog = log
        return Harness(controller: controller, window: window, log: log, directory: directory)
    }

    @Test func aMoveOutOfATextFieldIsWrittenAsSuspect() async throws {
        let h = try Self.harness()
        defer { h.close() }
        let content = try #require(h.window.contentView)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 22))
        let target = Target(frame: NSRect(x: 20, y: 60, width: 200, height: 200))
        content.addSubview(field)
        content.addSubview(target)
        #expect(h.window.makeFirstResponder(field))
        #expect(h.window.makeFirstResponder(target))
        let lines = try await h.lines()
        let move = try #require(lines.last { $0.kind == .responder && ($0.to ?? "").contains("Target") })
        #expect(move.from?.contains("typing") == true, "from the field's editor: \(move)")
        #expect(move.input == "none")
        #expect(move.suspect, "no key or click moved it: \(move)")
        #expect(!move.stack.isEmpty, "the stack names the caller")
    }

    /// AppKit drops the first responder to the window when the focused view leaves it, with or
    /// without calling `makeFirstResponder`: the log has the drop either way, with its stack.
    @Test func removingTheFocusedViewIsWritten() async throws {
        let h = try Self.harness()
        defer { h.close() }
        let content = try #require(h.window.contentView)
        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 22))
        content.addSubview(field)
        #expect(h.window.makeFirstResponder(field))
        let before = try await h.lines().count
        field.removeFromSuperview()
        // AppKit may drop the responder with no `makeFirstResponder`: the next key-down sees it.
        let key = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: h.window.windowNumber,
                                                context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        let reported = try await h.lines().dropFirst(before)
        h.log.noteInput(key)
        let drops = try await h.lines().dropFirst(before)
        let drop = try #require(drops.first { ($0.kind == .responder || $0.kind == .silent) && $0.to == "window" }, "lines: \(Array(drops))")
        #expect(drop.from?.contains("typing") == true)
        #expect(drop.suspect)
        // Which path AppKit took, for the audit (plans/cmux-next/focus-loss-AUDIT.md): a reported
        // drop has its stack; a silent one is named at the next key-down.
        print("focus-log removal path: \(reported.isEmpty ? "silent" : "makeFirstResponder") \(Array(reported))")
    }

    @Test func offWritesNothing() async throws {
        let h = try Self.harness(enabled: false)
        defer { h.close() }
        let content = try #require(h.window.contentView)
        let target = Target(frame: NSRect(x: 20, y: 60, width: 200, height: 200))
        content.addSubview(target)
        #expect(h.window.makeFirstResponder(target))
        #expect(try await h.lines().isEmpty)
    }
}
