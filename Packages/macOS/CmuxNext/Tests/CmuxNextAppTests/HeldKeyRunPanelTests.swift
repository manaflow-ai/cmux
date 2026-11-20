import AppKit
@testable import CmuxNextApp
import CmuxNextFocusUI
import CmuxNextTestSupport
import Foundation
import Testing

/// The app's last check of a key-down, `CrossWindowInputGuard.drops(keyTypedInto:keyWindow:router:)` (what
/// `CmuxApplication.sendEvent` asks), for the keys a creation hold runs again with `NSApp.sendEvent`, which goes to the
/// key window (review of #35832). A held line typed in a cmux window never goes into a floating panel no cmux window
/// owns that was key when its run began: the person opened it during the hold (the Quick Agent Chat, the Chief pet's
/// reply box), and a window keeps its first responder when it stops being key. When an earlier held key of the same run
/// opened that panel (Start Agent, then its line), the person typed the line for it: the keys follow it, in order, as
/// they did before the check.
@MainActor @Suite(.serialized, .closesItsWindows)
struct HeldKeyRunPanelTests {
    /// A panel no cmux window owns (no parent, no sheet parent), as the Quick Agent Chat and the Chief pet's reply box.
    private static func panel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.titled, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        return panel
    }

    /// Opens a creation hold in the harness window, types `keys` into it (each must be held), puts `keyWindow` as the app's
    /// key window, and lets the hold end: the keys run again through the harness's replay.
    private static func holdAndRun(_ keys: [(String, UInt16)], keyWindow: NSWindow, _ h: PersonTerminalKeyboardClaimTests.Harness) async throws {
        let router = h.services.keyRouter
        let coordinator = router.creationInputCoordinator
        coordinator.holdLimit = .milliseconds(100)
        let ticket = try #require(coordinator.begin(in: h.window, generation: h.controller.focus.beginIntent()), "the creation opened no key hold")
        for (characters, code) in keys {
            let held = router.interceptKeyDown(try PersonTerminalKeyboardClaimTests.key(characters, keyCode: code, in: h.window), in: h.window)
            #expect(held, "the hold did not take \(characters)")
        }
        h.services.keyWindowSource = { keyWindow }
        coordinator.resolve(ticket, landed: true, in: h.window)
        try await PasswordManagerRouteTests.until({ !coordinator.isHolding(in: h.window) }, report: { "the hold never ended" })
    }

    /// The panel became key during the hold (out of band: a click on the Chief pet, the menu bar, a system-wide key): every
    /// held key is dropped. A key the person types now in the window still reaches the panel they opened.
    @Test func aHeldLineNeverReachesAPanelThatWasKeyWhenItsRunBegan() async throws {
        let panel = Self.panel()
        defer { panel.close() }
        var decisions: [(key: String, dropped: Bool)] = []
        try await PersonTerminalKeyboardClaimTests.withWindow(replay: { event, window, router in
            let keyWindow = router.services?.keyWindowSource()
            decisions.append((key: event.characters ?? "", dropped: CrossWindowInputGuard.drops(keyTypedInto: window, keyWindow: keyWindow, router: router)))
        }) { h in
            try await Self.holdAndRun([("l", 37), ("s", 1)], keyWindow: panel, h)
            #expect(decisions.map({ $0.key }) == ["l", "s"], "the held keys did not run again in order: \(decisions)")
            #expect(decisions.allSatisfy({ $0.dropped }), "a held key reached the panel that was key when its run began: \(decisions)")
            let typedNow = CrossWindowInputGuard.drops(keyTypedInto: h.window, keyWindow: panel, router: h.services.keyRouter)
            #expect(!typedNow, "a key typed now did not reach the panel the person opened")
        }
    }

    /// An earlier held key of the run made the panel key (Start Agent's key opens its panel in its turn): the held keys
    /// after it follow the panel, in order; none is dropped.
    @Test func heldKeysFollowAPanelAnEarlierKeyOfTheirRunMadeKey() async throws {
        let panel = Self.panel()
        defer { panel.close() }
        var decisions: [(key: String, dropped: Bool)] = []
        try await PersonTerminalKeyboardClaimTests.withWindow(replay: { event, window, router in
            let keyWindow = router.services?.keyWindowSource()
            decisions.append((key: event.characters ?? "", dropped: CrossWindowInputGuard.drops(keyTypedInto: window, keyWindow: keyWindow, router: router)))
            if event.characters == "o" { router.services?.keyWindowSource = { panel } } // this key opens the panel, key at once
        }) { h in
            try await Self.holdAndRun([("o", 31), ("l", 37), ("s", 1)], keyWindow: h.window, h)
            #expect(decisions.map({ $0.key }) == ["o", "l", "s"], "the held keys did not run again in order: \(decisions)")
            #expect(!decisions.contains(where: { $0.dropped }), "a held key typed for the panel its own run opened was dropped: \(decisions)")
        }
    }
}
