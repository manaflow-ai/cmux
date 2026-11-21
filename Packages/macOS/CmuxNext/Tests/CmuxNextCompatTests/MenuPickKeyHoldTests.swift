import AppKit
import CmuxNextCompat
import Testing

/// File > New Tab, then typing at once: AppKit blinks the picked item for about 300 ms and runs its action only after
/// the menu's tracking ends, but keys typed during the blink reach `NSApplication.sendEvent` at once. They went to
/// whatever had focus before the action (the old tab), and the new tab's field stayed empty (cmux-lawrence-2,
/// 2026-11-12). Keys that arrive while a menu tracks wait and run after the menu's action, in typing order.
@MainActor
@Suite struct MenuPickKeyHoldTests {
    private let center = NotificationCenter()
    private let menu = NSMenu(title: "File")

    private static func key(_ character: String) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: 0))
    }

    /// A hold whose "next turn" runs when the test says, so the test sees what runs before and after the menu's action.
    private func hold(replayed: @escaping @MainActor (String) -> Void, turns: @escaping @MainActor (@escaping @MainActor () -> Void) -> Void) -> MenuPickKeyHold {
        MenuPickKeyHold(tracking: MenuTracking(center: center), replay: { replayed($0.characters ?? "") }, afterMenuAction: turns)
    }

    @Test func keysTypedDuringAPickedItemsBlinkRunAfterItsActionInOrder() throws {
        var replayed: [String] = []
        var pending: [@MainActor () -> Void] = []
        let hold = hold(replayed: { replayed.append($0) }, turns: { pending.append($0) })

        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        for character in ["h", "e", "l", "l", "o"] {
            #expect(hold.capture(try Self.key(character)), "a key typed during the menu's blink went on before the item's action ran")
        }
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(replayed.isEmpty, "the held keys ran before the item's action (it runs right after the tracking ends)")

        // The next turn, after the action: the keys go on, in typing order.
        pending.forEach { $0() }
        #expect(replayed == ["h", "e", "l", "l", "o"])
    }

    @Test func withNoMenuTrackingEveryKeyGoesOnAtOnce() throws {
        var replayed: [String] = []
        let hold = hold(replayed: { replayed.append($0) }, turns: { $0() })
        #expect(!hold.capture(try Self.key("h")))
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(!hold.capture(try Self.key("i")), "a key after the menu closed was held")
        #expect(replayed.isEmpty)
    }

    @Test func aReplayedKeyIsNotHeldAgainAndALaterMenuHoldsItsOwnKeys() throws {
        var replayed: [String] = []
        var hold: MenuPickKeyHold?
        // The replay sends the key back through the app, which asks the hold again: it must go on.
        hold = self.hold(replayed: { character in
            if let event = try? Self.key(character), hold?.capture(event) == true { return }
            replayed.append(character)
        }, turns: { $0() })
        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(hold?.capture(try Self.key("a")) == true)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(replayed == ["a"])

        center.post(name: NSMenu.didBeginTrackingNotification, object: menu)
        #expect(hold?.capture(try Self.key("b")) == true)
        center.post(name: NSMenu.didEndTrackingNotification, object: menu)
        #expect(replayed == ["a", "b"])
    }
}
