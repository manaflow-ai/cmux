import AppKit
import Carbon.HIToolbox
import Testing
@testable import CmuxNextRemoteView

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

