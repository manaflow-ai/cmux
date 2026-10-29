import AppKit
@testable import CmuxNextApp
import Testing

/// The cross-window stage `CmuxApplication.sendEvent` runs on every key-down: it
/// sits behind one window-number compare, so a key typed into the key window never asks the guard
/// (`CrossWindowInputGuard`). The guard's own judgement is MultiWindowInputRoutingTests'; the find
/// pill stage is FindPillTests'; the hint watcher's is ShortcutHintTests'.
@MainActor @Suite struct CrossWindowInputGuardTests {
    @Test func aKeyTypedIntoTheKeyWindowNeverAsksTheGuard() throws {
        let window = Self.window()
        defer { window.orderOut(nil) }
        var guardCalls = 0
        let keyGuard: (NSEvent, NSWindow?) -> Bool = { _, _ in guardCalls += 1; return true }
        for event in try [Self.keyDown("a", keyCode: 0, in: window), Self.keyDown(Self.left, keyCode: 123, in: window)] {
            let dropped = CmuxApplication.dropsCrossWindowKey(event, keyWindow: window, using: keyGuard)
            #expect(!dropped)
        }
        #expect(guardCalls == 0, "a key typed into the key window asked the cross-window guard")
    }

    /// The guard judges only a key whose window is not the key window, and its answer stands.
    @Test func theGuardJudgesOnlyAKeyTypedIntoAnotherWindow() throws {
        let typedInto = Self.window(), key = Self.window()
        defer { [typedInto, key].forEach { $0.orderOut(nil) } }
        try #require(typedInto.windowNumber != key.windowNumber)
        let event = try Self.keyDown("a", keyCode: 0, in: typedInto)
        var asked: [NSWindow?] = []
        let drops: (NSEvent, NSWindow?) -> Bool = { _, window in asked.append(window); return true }
        let keeps: (NSEvent, NSWindow?) -> Bool = { _, window in asked.append(window); return false }
        let dropped = CmuxApplication.dropsCrossWindowKey(event, keyWindow: key, using: drops)
        let kept = !CmuxApplication.dropsCrossWindowKey(event, keyWindow: key, using: keeps)
        #expect(dropped && kept, "the guard's answer does not stand")
        #expect(asked.count == 2 && asked.allSatisfy { $0 === key })
        let noKeyWindow = CmuxApplication.dropsCrossWindowKey(event, keyWindow: nil, using: drops)
        let noGuard = CmuxApplication.dropsCrossWindowKey(event, keyWindow: key, using: nil)
        #expect(!noKeyWindow && !noGuard)
        #expect(asked.count == 2, "a key with no key window asked the guard")
    }

    private static let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))

    private static func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    private static func keyDown(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                      windowNumber: window.windowNumber, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }
}
