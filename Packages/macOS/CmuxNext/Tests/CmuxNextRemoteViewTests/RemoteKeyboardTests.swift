import AppKit
import Carbon.HIToolbox
import Testing
@testable import CmuxNextRemoteView

struct RemoteKeyboardStateTests {
    private func key(_ id: UInt32, _ down: Bool) -> RemoteInputEvent { .key(usage: 0x0007_0000 | id, down: down) }

    @Test func leftAndRightShiftAreSeparateKeys() {
        var state = RemoteKeyboardState()
        #expect(state.flagsChanged(keyCode: UInt16(kVK_Shift), flags: .shift) == [key(0xE1, true)])
        #expect(state.flagsChanged(keyCode: UInt16(kVK_RightShift), flags: .shift) == [key(0xE5, true)])
        // Releasing the left one keeps the family flag (right still down).
        #expect(state.flagsChanged(keyCode: UInt16(kVK_Shift), flags: .shift) == [key(0xE1, false)])
        #expect(state.flagsChanged(keyCode: UInt16(kVK_RightShift), flags: []) == [key(0xE5, false)])
        #expect(state.heldKeys.isEmpty)
    }

    @Test func clearedFamilyFlagReleasesAMissedUp() {
        var state = RemoteKeyboardState()
        _ = state.flagsChanged(keyCode: UInt16(kVK_Command), flags: .command)
        _ = state.flagsChanged(keyCode: UInt16(kVK_RightCommand), flags: .command)
        // One flagsChanged was lost: the family flag is clear, both go up.
        let events = state.flagsChanged(keyCode: UInt16(kVK_Command), flags: [])
        #expect(Set(events) == [key(0xE3, false), key(0xE7, false)])
        #expect(state.heldKeys.isEmpty)
    }

    @Test func capsLockSendsATap() {
        var state = RemoteKeyboardState()
        #expect(state.flagsChanged(keyCode: UInt16(kVK_CapsLock), flags: .capsLock) == [key(0x39, true), key(0x39, false)])
        #expect(state.heldKeys.isEmpty)
    }

    @Test func repeatsAreTheHostsJobAndReleaseAllLiftsEverything() {
        var state = RemoteKeyboardState()
        #expect(state.keyDown(keyCode: UInt16(kVK_ANSI_A), isRepeat: false) == [key(0x04, true)])
        #expect(state.keyDown(keyCode: UInt16(kVK_ANSI_A), isRepeat: true).isEmpty)
        _ = state.flagsChanged(keyCode: UInt16(kVK_Control), flags: .control)
        _ = state.buttonDown(.left)
        let released = state.releaseAll()
        #expect(Set(released) == [key(0x04, false), key(0xE0, false), .button(.left, down: false)])
        #expect(state.releaseAll().isEmpty)
        #expect(state.keyUp(keyCode: UInt16(kVK_ANSI_A)).isEmpty)
    }
}

struct RemoteKeyboardPolicyTests {
    private func route(
        _ keyCode: Int, _ flags: NSEvent.ModifierFlags = [], mode: RemoteKeyboardMode = .auto,
        system: Bool = false, ascii: Bool = true, local: Bool = false
    ) -> RemoteKeyboardPolicy.Route {
        RemoteKeyboardPolicy().route(
            keyCode: UInt16(keyCode), modifiers: flags, mode: mode, sendSystemShortcuts: system,
            inputSourceIsASCIICapable: ascii, isLocalShortcut: local)
    }

    @Test func systemShortcutsStayLocalUnlessSendingIsOn() {
        #expect(route(kVK_Tab, .command) == .local)
        #expect(route(kVK_Space, .command) == .local)
        #expect(route(kVK_Space, .control) == .local)
        #expect(route(kVK_LeftArrow, .control) == .local)
        #expect(route(kVK_ANSI_Q, .command) == .local)
        #expect(route(kVK_Tab, .command, system: true) == .physical)
        #expect(route(kVK_ANSI_C, .command) == .physical)
        #expect(route(kVK_LeftArrow) == .physical)
    }

    @Test func cmuxShortcutsFollowTheAppMatcher() {
        #expect(route(kVK_ANSI_T, .command, local: true) == .local)
        #expect(route(kVK_ANSI_T, .command, system: true, local: true) == .physical)
    }

    @Test func releaseChordAlwaysWins() {
        #expect(route(kVK_Escape, [.control, .option]) == .releaseKeyboard)
        #expect(route(kVK_Escape, [.control, .option], system: true) == .releaseKeyboard)
        #expect(route(kVK_Escape, .control) == .physical)
        let custom = RemoteReleaseChord(keyCode: UInt16(kVK_F12), modifiers: .command)
        #expect(RemoteKeyboardPolicy().route(
            keyCode: UInt16(kVK_F12), modifiers: .command, mode: .auto, sendSystemShortcuts: false,
            inputSourceIsASCIICapable: true, releaseChord: custom) == .releaseKeyboard)
        #expect(RemoteReleaseChord.shortcutID == "remoteDesktop.releaseKeyboard")
    }

    @Test func keyboardModesRouteTextKeys() {
        #expect(route(kVK_ANSI_A, mode: .physical, ascii: false) == .physical)
        #expect(route(kVK_ANSI_A, mode: .text) == .textInput)
        #expect(route(kVK_ANSI_A, mode: .auto, ascii: true) == .physical)
        #expect(route(kVK_ANSI_A, mode: .auto, ascii: false) == .textInput)
        // Keys that type nothing stay physical even in text mode.
        #expect(route(kVK_Return, mode: .text) == .physical)
        #expect(route(kVK_LeftArrow, mode: .text) == .physical)
        #expect(route(kVK_ANSI_A, .control, mode: .text) == .physical)
        #expect(route(kVK_ANSI_Keypad5, mode: .text) == .textInput)
    }
}

struct RemoteInputEventTests {
    @Test func textSplitsOnCharacterBoundariesUnderTheWireLimit() {
        let text = String(repeating: "é", count: 200) // 400 bytes of UTF-8
        let events = RemoteInputEvent.textEvents(text)
        var joined = ""
        for case let .text(chunk) in events {
            #expect(chunk.utf8.count <= RemoteInputEvent.maxTextBytes)
            joined += chunk
        }
        #expect(events.count == 2)
        #expect(joined == text)
        #expect(RemoteInputEvent.textEvents("").isEmpty)
    }

    @Test func buttonsMapFromAppKitNumbers() {
        #expect(RemoteMouseButton(appKitButtonNumber: 0) == .left)
        #expect(RemoteMouseButton(appKitButtonNumber: 1) == .right)
        #expect(RemoteMouseButton(appKitButtonNumber: 2) == .middle)
        #expect(RemoteMouseButton(appKitButtonNumber: 9) == nil)
    }

    @Test func scrollCarriesRemaindersAndResetsOnANewGesture() {
        var accumulator = RemoteScrollAccumulator()
        #expect(accumulator.add(deltaX: 0, deltaY: 0.004, precise: true, phase: .began, momentumPhase: []) == nil)
        #expect(accumulator.add(deltaX: 0, deltaY: 0.004, precise: true, phase: .changed, momentumPhase: []) == nil)
        // 0.012 points carried = 1.2 hundredths: one is sent, 0.2 kept.
        #expect(accumulator.add(deltaX: 0, deltaY: 0.004, precise: true, phase: .changed, momentumPhase: [])
            == .scroll(dx: 0, dy: 1, precise: true))
        #expect(accumulator.add(deltaX: -2.5, deltaY: 0, precise: false, phase: [], momentumPhase: [])
            == .scroll(dx: -250, dy: 0, precise: false))
        // A new gesture drops the old remainder.
        _ = accumulator.add(deltaX: 0, deltaY: 0.009, precise: true, phase: .began, momentumPhase: [])
        #expect(accumulator.add(deltaX: 0, deltaY: 0.009, precise: true, phase: .began, momentumPhase: []) == nil)
    }
}
