import AppKit
@testable import CmuxNextApp
import CmuxNextTerminal
import Testing

/// P0 1193 (cmux-ad 11:3xZ): a key held for a terminal with no view is typed by the daemon (`send-key` / `send`). The
/// same bytes must reach that terminal as a key press in its view sends: Ghostty's `macos-option-as-alt` makes Option
/// Alt (ESC and the base key) there, so the daemon path reads the same setting.
@MainActor @Suite struct HeldKeyInputTests {
    /// Option-A as macOS gives it ("å"), with the left or right Option key's device bit.
    private static func optionA(left: Bool) throws -> NSEvent {
        let flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.option.rawValue | (left ? 0x20 : 0x40))
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                             context: nil, characters: "å", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
    }

    private static func key(_ characters: String, _ flags: NSEvent.ModifierFlags, ignoring: String? = nil, code: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                                      characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code))
    }

    @Test func optionIsAltWhenTheSettingSaysSo() throws {
        let left = try Self.optionA(left: true), right = try Self.optionA(left: false)
        #expect(HeldKeyInput(left, optionAsAlt: "true") == .key("alt+a"))
        #expect(HeldKeyInput(right, optionAsAlt: "true") == .key("alt+a"))
        #expect(HeldKeyInput(left, optionAsAlt: "left") == .key("alt+a"))
        #expect(HeldKeyInput(right, optionAsAlt: "left") == .text("å"), "the right Option key composes when only the left one is Alt")
        #expect(HeldKeyInput(right, optionAsAlt: "right") == .key("alt+a"))
        #expect(HeldKeyInput(left, optionAsAlt: "false") == .text("å"))
        #expect(HeldKeyInput(left, optionAsAlt: nil) == .text("å"))
    }

    @Test func theSettingIsReadFromTheGhosttyConfig() {
        _ = GhosttyRuntime.shared // ghostty_config_new needs ghostty_init
        #expect(GhosttyRuntime.optionAsAltValue(configText: "macos-option-as-alt = left") == "left")
        #expect(GhosttyRuntime.optionAsAltValue(configText: "macos-option-as-alt = true") == "true")
    }

    @Test func controlArrowsAndTextKeepTheirOrder() throws {
        let events = [try Self.key("l", [], code: 37), try Self.key("s", [], code: 1), try Self.key("\u{F700}", [.function, .numericPad], code: 126),
                      try Self.key("\u{3}", [.control], ignoring: "c", code: 8), try Self.key("\r", [], code: 36)]
        let (inputs, skipped) = HeldKeyInput.inputs(for: events, optionAsAlt: nil)
        #expect(inputs == [.text("ls"), .key("up"), .key("ctrl+c"), .key("enter")])
        #expect(skipped == 0)
    }
}
