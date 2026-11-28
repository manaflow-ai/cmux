import AppKit
@testable import CmuxNextSidebar
import Testing

/// The Priority view's filter chips from the keyboard: Space and Return pick the focused chip, the
/// arrow keys pick the chip beside it (wrapping, as a radio group does), and each chip reads as a
/// radio button whose value is whether it is picked.
@MainActor
struct SidebarPriorityFilterChipKeysTests {
    @MainActor final class Picks {
        var filters: [SidebarPriorityFilter] = []
    }

    private static func key(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                                      context: nil, characters: characters, charactersIgnoringModifiers: characters,
                                      isARepeat: false, keyCode: code))
    }

    private static func arrow(_ function: Int, code: UInt16) throws -> NSEvent {
        try key(String(Character(try #require(UnicodeScalar(function)))), code: code, flags: [.function, .numericPad])
    }

    private static func bar() -> (SidebarPriorityFilterBarView, Picks) {
        let bar = SidebarPriorityFilterBarView(frame: NSRect(x: 0, y: 0, width: 260, height: SidebarPriorityFilterBarView.height))
        let picks = Picks()
        bar.onAction = { action in
            if case .setFilter(let filter) = action { picks.filters.append(filter) }
        }
        return (bar, picks)
    }

    @Test func spaceAndReturnPickTheFocusedChip() throws {
        let (bar, picks) = Self.bar()
        bar.chips[1].keyDown(with: try Self.key(" ", code: 49))
        bar.chips[3].keyDown(with: try Self.key("\r", code: 36))
        #expect(picks.filters == [.waiting, .running])
    }

    @Test func arrowsPickTheChipBesideAndWrap() throws {
        let (bar, picks) = Self.bar()
        bar.chips[0].keyDown(with: try Self.arrow(NSRightArrowFunctionKey, code: 124))
        bar.chips[0].keyDown(with: try Self.arrow(NSLeftArrowFunctionKey, code: 123))
        bar.chips[3].keyDown(with: try Self.arrow(NSDownArrowFunctionKey, code: 125))
        bar.chips[2].keyDown(with: try Self.arrow(NSUpArrowFunctionKey, code: 126))
        #expect(picks.filters == [.waiting, .running, .all, .waiting])
    }

    @Test func chipsReadAsRadioButtons() {
        let (bar, _) = Self.bar()
        bar.show(SidebarPriorityFilterBar(selected: .unread))
        #expect(bar.accessibilityRole() == .radioGroup)
        #expect(bar.chips.allSatisfy { $0.accessibilityRole() == .radioButton })
        #expect(bar.chips.map { ($0.accessibilityValue() as? NSNumber)?.boolValue } == [false, false, true, false])
    }
}
