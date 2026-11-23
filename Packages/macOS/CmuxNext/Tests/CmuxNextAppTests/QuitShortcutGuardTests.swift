import AppKit
import CmuxNextActions
@testable import CmuxNextApp
@testable import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextSettings
import Testing

/// Cmd-Q's guard against an accidental quit (https://github.com/manaflow-ai/cmux/issues/48621:
/// "i dont want to accidentally do cmd q and then quit it should warn me somehow"). The first
/// press asks "Quit cmux?"; holding it for 0.8 s or pressing it again quits, like Chrome's
/// "Warn Before Quitting", and the question has "Don't ask again".
@MainActor @Suite struct QuitShortcutGuardTests {
    static let qKeyCode: UInt16 = 12

    static func key(_ characters: String = "q", at timestamp: TimeInterval, _ modifiers: NSEvent.ModifierFlags = [.command],
                    repeat isRepeat: Bool = false, keyCode: UInt16 = qKeyCode) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: isRepeat, keyCode: keyCode))
    }

    @Test func firstPressWarnsAndASecondInTimeQuits() {
        var presses = QuitShortcutPresses()
        #expect(presses.press(isRepeat: false, timestamp: 10) == .warn)
        #expect(presses.isArmed)
        #expect(presses.press(isRepeat: false, timestamp: 11.5) == .quit)
        #expect(!presses.isArmed)
        // After a quit that did not end the app (an unsaved document's Cancel), the next press warns again.
        #expect(presses.press(isRepeat: false, timestamp: 12) == .warn)
    }

    @Test func aSecondPressWhileArmedQuitsHoweverLate() {
        // The question stays until it is answered, so a press minutes later still means "quit".
        var presses = QuitShortcutPresses()
        #expect(presses.press(isRepeat: false, timestamp: 10) == .warn)
        #expect(presses.press(isRepeat: false, timestamp: 300) == .quit)
    }

    @Test func holdingQuitsOnlyAfterTheHoldDuration() {
        var presses = QuitShortcutPresses()
        #expect(presses.press(isRepeat: false, timestamp: 10) == .warn)
        #expect(presses.press(isRepeat: true, timestamp: 10.3) == .wait)
        #expect(presses.press(isRepeat: true, timestamp: 10.5) == .wait)
        #expect(presses.press(isRepeat: true, timestamp: 10 + QuitShortcutPresses.holdDuration) == .quit)
    }

    @Test func aRepeatWithNothingArmedNeitherWarnsNorQuits() {
        var presses = QuitShortcutPresses()
        #expect(presses.press(isRepeat: true, timestamp: 10) == .wait)
        #expect(!presses.isArmed)
    }

    @Test func oneKeyDownSeenTwiceCountsOnce() {
        var presses = QuitShortcutPresses()
        #expect(presses.press(isRepeat: false, timestamp: 10) == .warn)
        // The same event through the key dispatcher and the menu's key equivalent.
        #expect(presses.press(isRepeat: false, timestamp: 10) == .wait)
        #expect(presses.isArmed)
    }

    @Test func resetDisarms() {
        var presses = QuitShortcutPresses()
        _ = presses.press(isRepeat: false, timestamp: 10)
        presses.reset()
        #expect(presses.press(isRepeat: false, timestamp: 10.5) == .warn)
    }

    @Test func onlyACommandKeyDownIsTheShortcut() throws {
        #expect(QuitShortcutGuard.isShortcutPress(try Self.key(at: 1)))
        // The palette's Return on its Quit row, and no event at all (a menu pick after tracking).
        #expect(!QuitShortcutGuard.isShortcutPress(try Self.key("\r", at: 1, [], keyCode: 36)))
        #expect(!QuitShortcutGuard.isShortcutPress(nil))
    }

    @Test func theHeldShortcutsRepeatsQuitThroughTheMonitor() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        var removed = 0
        let quitGuard = QuitShortcutGuard(addMonitor: { handler = $0; return "monitor" }, removeMonitor: { _ in removed += 1 })
        var quits = 0, disarms = 0
        quitGuard.onHeldQuit = { quits += 1 }
        quitGuard.onDisarm = { disarms += 1 }

        #expect(quitGuard.press(try Self.key(at: 10)) == .warn)
        let monitor = try #require(handler)
        // Another key passes through untouched; an early repeat is the guard's and quits nothing.
        let other = try Self.key("a", at: 10.1, [], keyCode: 0)
        #expect(monitor(other) === other)
        #expect(monitor(try Self.key(at: 10.3, repeat: true)) == nil)
        #expect(quits == 0)
        #expect(monitor(try Self.key(at: 10.9, repeat: true)) == nil)
        #expect(quits == 1)
        #expect(disarms == 1)
        #expect(removed == 1)
        #expect(!quitGuard.presses.isArmed)
    }

    @Test func holdingAnotherShortcutOnTheSameKeyNeverQuits() throws {
        var handler: ((NSEvent) -> NSEvent?)?
        let quitGuard = QuitShortcutGuard(addMonitor: { handler = $0; return "monitor" }, removeMonitor: { _ in })
        var quits = 0
        quitGuard.onHeldQuit = { quits += 1 }
        #expect(quitGuard.press(try Self.key(at: 10)) == .warn)
        let monitor = try #require(handler)
        // ⌘⇧Q held after the warning: its repeats pass through and never count as holding ⌘Q.
        let shifted = try Self.key("Q", at: 11, [.command, .shift], repeat: true)
        #expect(monitor(shifted) === shifted)
        #expect(monitor(try Self.key("Q", at: 12, [.command, .shift], repeat: true)) != nil)
        #expect(quits == 0)
        #expect(quitGuard.presses.isArmed)
    }

    @Test func aSecondPressQuitsAndRemovesTheMonitor() throws {
        var removed = 0
        let quitGuard = QuitShortcutGuard(addMonitor: { _ in "monitor" }, removeMonitor: { _ in removed += 1 })
        #expect(quitGuard.press(try Self.key(at: 10)) == .warn)
        #expect(quitGuard.press(try Self.key(at: 11)) == .quit)
        #expect(removed == 1)
    }

    @Test func disarmEndsTheWarningAndTheMonitor() throws {
        var removed = 0, disarms = 0
        let quitGuard = QuitShortcutGuard(addMonitor: { _ in "monitor" }, removeMonitor: { _ in removed += 1 })
        quitGuard.onDisarm = { disarms += 1 }
        #expect(quitGuard.press(try Self.key(at: 10)) == .warn)
        quitGuard.disarm()
        #expect(removed == 1)
        #expect(disarms == 1)
        #expect(quitGuard.press(try Self.key(at: 10.5)) == .warn)
    }

    @Test func theSettingIsOnUnlessTurnedOff() {
        let unset = CmuxConfigSnapshot.parse(.object([:]), validDensities: [], validMetrics: [])
        #expect(unset.warnBeforeQuitShortcut)
        let off = CmuxConfigSnapshot.parse(.object(["app": .object(["warnBeforeQuitShortcut": .bool(false)])]), validDensities: [], validMetrics: [])
        #expect(!off.warnBeforeQuitShortcut)
        let invalid = CmuxConfigSnapshot.parse(.object(["app": .object(["warnBeforeQuitShortcut": .string("no")])]), validDensities: [], validMetrics: [])
        #expect(invalid.warnBeforeQuitShortcut)
        #expect(SettingsSchema.all.contains { $0.path == CmuxConfigSnapshot.warnBeforeQuitShortcutPath })
    }

    @Test func onlyAPersonsShortcutRunWithTheSettingOnIsHeld() throws {
        let quitGuard = QuitShortcutGuard(addMonitor: { _ in "monitor" }, removeMonitor: { _ in })
        var warned: [String] = []
        let warn: (String) -> Bool = { warned.append($0); return true }
        var menu = ActionInvocation()
        menu.menuPick = true
        var socket = ActionInvocation()
        socket.viaControlSocket = true
        #expect(!quitGuard.holds(menu, event: try Self.key(at: 1), enabled: true, warn: warn))
        #expect(!quitGuard.holds(socket, event: try Self.key(at: 2), enabled: true, warn: warn))
        #expect(!quitGuard.holds(ActionInvocation(origin: .cli), event: try Self.key(at: 3), enabled: true, warn: warn))
        #expect(!quitGuard.holds(ActionInvocation(), event: try Self.key(at: 4), enabled: false, warn: warn))
        #expect(!quitGuard.holds(ActionInvocation(), event: nil, enabled: true, warn: warn))
        #expect(warned.isEmpty)

        #expect(quitGuard.holds(ActionInvocation(), event: try Self.key(at: 10), enabled: true, warn: warn))
        #expect(warned == ["⌘Q"])
        #expect(!quitGuard.holds(ActionInvocation(), event: try Self.key(at: 11), enabled: true, warn: warn))
    }

    @Test func noWindowForTheWarningQuitsAtOnce() throws {
        let quitGuard = QuitShortcutGuard(addMonitor: { _ in "monitor" }, removeMonitor: { _ in })
        #expect(!quitGuard.holds(ActionInvocation(), event: try Self.key(at: 10), enabled: true, warn: { _ in false }))
        #expect(!quitGuard.presses.isArmed)
    }

    @Test func theQuestionOffersQuitAndDontAskAgain() {
        let prompt = QuitCoordinator.shortcutPrompt("⌘Q")
        #expect(prompt.suppresses == CmuxConfigSnapshot.warnBeforeQuitShortcutPath)
        #expect(prompt.body.contains("⌘Q"))
        let spec = DestructiveConfirmation.spec(prompt)
        #expect(spec.defaultButton?.id == DestructiveConfirmation.confirmID)
        #expect(spec.fields.count == 1)
    }
}
