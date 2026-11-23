import AppKit
@testable import CmuxNextDesign
import Testing

/// The browser More menu on cmux's glass (Lawrence, 2026-11-20: "let's stop using native macos for
/// that and make it super good"): a zoom row whose −, + and reset run and leave the menu open, the
/// menu's keys (arrows, Return, Escape, typing to jump) and VoiceOver labels.
@MainActor @Suite struct GlassMenuStepperTests {
    /// A menu like the More menu: Find, the zoom row, a disabled row, History, Help, Settings.
    private struct Fixture {
        let menu = NSMenu()
        let target = GlassMenuStepperTarget()
        let zoom: GlassMenuStepperItem
        let glass: GlassMenu
        var closes = 0

        init() {
            let menu = menu, target = target
            menu.autoenablesItems = false
            let parts = ["Zoom Out", "Zoom In", "Actual Size"].map { title in
                let item = NSMenuItem(title: title, action: #selector(GlassMenuStepperTarget.run(_:)), keyEquivalent: "")
                item.target = target
                return item
            }
            parts[0].keyEquivalent = "-"
            parts[1].keyEquivalent = "="
            parts[2].keyEquivalent = "0"
            parts.forEach { $0.keyEquivalentModifierMask = [.command] }
            zoom = GlassMenuStepperItem(title: "Zoom", decrement: parts[0], increment: parts[1], reset: parts[2]) {
                "\(target.percent)%"
            }
            let add = { (title: String) -> NSMenuItem in
                let item = menu.addItem(withTitle: title, action: #selector(GlassMenuStepperTarget.run(_:)), keyEquivalent: "")
                item.target = target
                return item
            }
            _ = add("Find…")
            menu.addItem(.separator())
            menu.addItem(zoom)
            menu.addItem(.separator())
            add("Disabled").isEnabled = false
            for title in ["History", "Help", "Settings…"] { _ = add(title) }
            glass = GlassMenu(menu: menu)
            glass.loadRows()
        }

        var list: GlassMenuListView { glass.list }
        var zoomIndex: Int { (0..<list.rowCount).first { list.row(at: $0)?.item === zoom }! }
        var zoomRow: GlassMenuStepperRowView { list.stepperRow(at: zoomIndex)! }
        func title(at index: Int?) -> String? { index.flatMap { list.row(at: $0)?.item?.title } }
    }

    private static func key(_ code: UInt16, _ characters: String = "", flags: NSEvent.ModifierFlags = [],
                            at time: TimeInterval = 0) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: time,
                                      windowNumber: 0, context: nil, characters: characters,
                                      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    private static func turnRunLoop() {
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue) {}
        _ = CFRunLoopRunInMode(.defaultMode, 0, false)
    }

    @Test func theZoomButtonsRunAndTheMenuStaysOpen() throws {
        var fixture = Fixture()
        fixture.glass.onClose = { fixture.closes += 1 }
        let row = fixture.zoomRow
        #expect(row.valueLabel.stringValue == "100%")
        #expect(row.plus.press())
        #expect(fixture.target.ran == ["Zoom In"], "+ ran Zoom In at once, with the menu open")
        #expect(row.valueLabel.stringValue == "110%", "the row shows the new zoom after the press")
        #expect(row.minus.press())
        #expect(row.resetButton.press())
        #expect(fixture.target.ran == ["Zoom In", "Zoom Out", "Actual Size"])
        // A click on the row itself, away from its buttons, runs nothing and keeps the menu.
        row.activate()
        Self.turnRunLoop()
        #expect(fixture.closes == 0, "a zoom press closed the menu")
    }

    @Test func aDisabledZoomButtonDoesNotRun() {
        let fixture = Fixture()
        // As the action registry disables a row: its target's validation says no.
        fixture.target.disabled = ["Actual Size"]
        fixture.zoomRow.refresh()
        #expect(!fixture.zoomRow.resetButton.isEnabled)
        #expect(!fixture.zoomRow.resetButton.press())
        #expect(fixture.target.ran.isEmpty)
    }

    @Test func zoomShortcutsStepTheRowWithTheMenuOpen() throws {
        var fixture = Fixture()
        fixture.glass.onClose = { fixture.closes += 1 }
        #expect(fixture.glass.runKeyEquivalent(try Self.key(24, "=", flags: .command)))
        #expect(fixture.glass.runKeyEquivalent(try Self.key(24, "=", flags: .command)))
        Self.turnRunLoop()
        #expect(fixture.target.ran == ["Zoom In", "Zoom In"], "⌘= ran Zoom In after the key, as the + button does")
        #expect(fixture.zoomRow.valueLabel.stringValue == "120%")
        #expect(fixture.closes == 0)
    }

    /// The App's action rows validate as disabled while a key it already handled is dispatched
    /// (`ActionMenuTarget` asks the key router's gate for every row with a shortcut, and the zoom
    /// buttons have ⌘- ⌘= ⌘0). A zoom key in the open menu is a pick, as a click is: it runs after
    /// that key, so the zoom changes and the buttons stay enabled. Live VoiceOver capture on the
    /// fleet (cmux21, 2026-11-21): Right on the zoom row left it at 100% with its buttons dimmed.
    @Test func zoomKeysRunAfterTheKeyThatPressedThem() throws {
        var fixture = Fixture()
        fixture.glass.onClose = { fixture.closes += 1 }
        let list = fixture.list
        list.keyDown(with: try Self.key(125))
        list.keyDown(with: try Self.key(125))
        #expect(list.highlightedIndex == fixture.zoomIndex)
        try fixture.target.dispatchingKey {
            list.keyDown(with: try Self.key(124))  // Right
            list.keyDown(with: try Self.key(124))
            #expect(fixture.glass.runKeyEquivalent(try Self.key(24, "=", flags: .command)))
        }
        Self.turnRunLoop()
        #expect(fixture.target.ran == ["Zoom In", "Zoom In", "Zoom In"], "a zoom key ran inside the key's own dispatch")
        #expect(fixture.zoomRow.valueLabel.stringValue == "130%")
        let row = fixture.zoomRow
        #expect(row.minus.isEnabled && row.plus.isEnabled && row.resetButton.isEnabled, "the zoom buttons read dimmed after a key")
        try fixture.target.dispatchingKey { list.keyDown(with: try Self.key(36, "\r")) }  // Return: Actual Size
        Self.turnRunLoop()
        #expect(fixture.zoomRow.valueLabel.stringValue == "100%")
        #expect(fixture.closes == 0)
    }

    @Test func arrowsMoveOverEnabledRowsAndLeftRightStepTheZoomRow() throws {
        var fixture = Fixture()
        fixture.glass.onClose = { fixture.closes += 1 }
        let list = fixture.list
        list.keyDown(with: try Self.key(125))  // Down
        #expect(fixture.title(at: list.highlightedIndex) == "Find…")
        list.keyDown(with: try Self.key(125))
        #expect(list.highlightedIndex == fixture.zoomIndex, "Down stops on the zoom row")
        list.keyDown(with: try Self.key(124))  // Right
        list.keyDown(with: try Self.key(124))
        list.keyDown(with: try Self.key(123))  // Left
        list.keyDown(with: try Self.key(36, "\r"))  // Return
        Self.turnRunLoop()
        #expect(fixture.target.ran == ["Zoom In", "Zoom In", "Zoom Out", "Actual Size"])
        list.keyDown(with: try Self.key(125))
        #expect(fixture.title(at: list.highlightedIndex) == "History", "Down skips the separator and the disabled row")
        list.keyDown(with: try Self.key(126))  // Up
        #expect(list.highlightedIndex == fixture.zoomIndex)
        Self.turnRunLoop()
        #expect(fixture.closes == 0)
    }

    @Test func typingJumpsToARowAndReturnRunsItAfterTheMenuCloses() throws {
        var fixture = Fixture()
        fixture.glass.onClose = { fixture.closes += 1 }
        let list = fixture.list
        list.keyDown(with: try Self.key(4, "h", at: 1))
        #expect(fixture.title(at: list.highlightedIndex) == "History")
        list.keyDown(with: try Self.key(4, "h", at: 1.2))
        #expect(fixture.title(at: list.highlightedIndex) == "Help", "the same letter again moves to the next row with it")
        list.keyDown(with: try Self.key(1, "s", at: 3))
        #expect(fixture.title(at: list.highlightedIndex) == "Settings…", "after a pause typing starts over")
        list.keyDown(with: try Self.key(4, "h", at: 5))
        list.keyDown(with: try Self.key(34, "i", at: 5.3))
        #expect(fixture.title(at: list.highlightedIndex) == "History", "letters typed together match a title's start")
        list.keyDown(with: try Self.key(36, "\r"))
        #expect(fixture.target.ran.isEmpty, "the row ran before the menu closed")
        Self.turnRunLoop()
        #expect(fixture.closes == 1)
        #expect(fixture.target.ran == ["History"])
    }

    @Test func escapeClosesTheMenuAndRunsNothing() throws {
        var fixture = Fixture()
        fixture.glass.onClose = { fixture.closes += 1 }
        fixture.list.keyDown(with: try Self.key(125))
        fixture.list.keyDown(with: try Self.key(53, "\u{1b}"))
        Self.turnRunLoop()
        #expect(fixture.closes == 1)
        #expect(fixture.target.ran.isEmpty)
    }

    @Test func voiceOverReadsTheZoomRowAndItsButtons() {
        let fixture = Fixture()
        let row = fixture.zoomRow
        #expect(row.accessibilityRole() == .menuItem, "VoiceOver reads the zoom row as one of the menu's items")
        #expect(row.accessibilityLabel() == "Zoom")
        #expect(row.accessibilityValue() as? String == "100%")
        for (button, label) in [(row.minus, "Zoom Out"), (row.plus, "Zoom In"), (row.resetButton, "Actual Size")] {
            #expect(button.accessibilityRole() == .button)
            #expect(button.accessibilityLabel() == label)
            #expect(button.themedToolTip == label, "the tooltip names the button")
            #expect(button.toolTip == nil, "the stock bubble drew")
        }
        #expect(row.plus.themedToolTipShortcut == "⌘=", "the tooltip's keycap shows the shortcut")
        #expect(row.plus.accessibilityPerformPress())
        #expect(fixture.target.ran == ["Zoom In"])
    }

    /// What the menu told VoiceOver: each notification with the row title it was about (nil: not a row).
    private final class Posts {
        var items: [(name: String, title: String?, announcement: String?)] = []
        func record(_ list: GlassMenuListView) {
            list.postAccessibility = { [unowned self] element, notification, info in
                let title = (element as? PopupRowView).map { $0.accessibilityLabel() ?? "" }
                self.items.append((notification.rawValue, title, info?[.announcement] as? String))
            }
        }
        var selected: [String?] { items.filter { $0.name == "AXMenuItemSelected" }.map(\.title) }
        var announced: [String] { items.compactMap(\.announcement) }
    }

    /// VoiceOver follows the menu's highlight (arrows, typing to jump) as it follows an `NSMenu`'s: the
    /// highlighted row is the selected one and the menu says each new one.
    @Test func voiceOverFollowsTheHighlight() throws {
        let fixture = Fixture()
        let posts = Posts()
        posts.record(fixture.list)
        let list = fixture.list
        list.keyDown(with: try Self.key(125))  // Down
        let findIndex = try #require(list.highlightedIndex)
        let find = try #require(list.view(at: findIndex))
        #expect(find.isAccessibilitySelected(), "the highlighted row is not selected for VoiceOver")
        list.keyDown(with: try Self.key(4, "h", at: 1))
        let historyIndex = try #require(list.highlightedIndex)
        let history = try #require(list.view(at: historyIndex))
        #expect(history.isAccessibilitySelected())
        #expect(!find.isAccessibilitySelected(), "the row the highlight left stays selected")
        #expect(posts.selected == ["Find…", "History"], "VoiceOver was not told of each new highlighted row")
    }

    /// On the zoom row VoiceOver says "Zoom, 100%", and the new zoom after each step.
    @Test func voiceOverSaysTheZoomRowAndEachNewZoom() throws {
        let fixture = Fixture()
        let posts = Posts()
        posts.record(fixture.list)
        let list = fixture.list
        list.keyDown(with: try Self.key(125))
        list.keyDown(with: try Self.key(125))
        #expect(list.highlightedIndex == fixture.zoomIndex)
        #expect(posts.selected.last == "Zoom")
        list.keyDown(with: try Self.key(124))  // Right: Zoom In
        Self.turnRunLoop()
        #expect(fixture.zoomRow.plus.press())
        #expect(posts.announced == ["110%", "120%"], "VoiceOver did not hear the new zoom")
    }

    /// A row the tab cannot run reads as dimmed, as a disabled `NSMenu` row does.
    @Test func aDisabledRowReadsDimmed() throws {
        let fixture = Fixture()
        let index = try #require((0..<fixture.list.rowCount).first { fixture.title(at: $0) == "Disabled" })
        #expect(fixture.list.view(at: index)?.isAccessibilityEnabled() == false)
        let history = try #require((0..<fixture.list.rowCount).first { fixture.title(at: $0) == "History" })
        #expect(fixture.list.view(at: history)?.isAccessibilityEnabled() == true)
    }

    @Test func theZoomRowIsAsTallAsAMenuRow() {
        let fixture = Fixture()
        let size = fixture.list.fittingMenuSize()
        let rows = 5 * GlassMenuMaterial.rowHeight + 2 * GlassMenuListView.separatorHeight
        // Find, zoom, Disabled, History, Help, Settings (6 rows) and two separators.
        #expect(size.height == MenuMetrics.highlightInset * 2 + rows + GlassMenuMaterial.rowHeight)
    }
}

/// The type-to-jump rule alone.
@MainActor @Suite struct GlassMenuTypeSelectTests {
    @Test func lettersMatchTitleStartsIgnoringCaseAndAccents() {
        var select = GlassMenuTypeSelect()
        let titles: [String?] = ["Find…", nil, "Émulate Device…", "History", "Help", nil, "Settings…"]
        #expect(select.pick("e", at: 0, titles: titles, current: nil) == 2)
        #expect(select.pick("h", at: 5, titles: titles, current: 2) == 3)
        #expect(select.pick("h", at: 5.5, titles: titles, current: 3) == 4)
        #expect(select.pick("h", at: 6, titles: titles, current: 4) == 3, "a repeated letter wraps")
        #expect(select.pick("x", at: 9, titles: titles, current: nil) == nil)
    }
}

@MainActor final class GlassMenuStepperTarget: NSObject, NSMenuItemValidation {
    var ran: [String] = []
    var percent = 100
    /// The titles whose items validate as disabled.
    var disabled: Set<String> = []

    /// A key-down is being dispatched: rows with a shortcut validate as disabled, as the App's
    /// `ActionMenuTarget` does when its key router already handled the key.
    private(set) var isDispatchingKey = false

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        !disabled.contains(menuItem.title) && !(isDispatchingKey && !menuItem.keyEquivalent.isEmpty)
    }

    /// Runs `body` as the handling of a key-down.
    func dispatchingKey(_ body: () throws -> Void) rethrows {
        isDispatchingKey = true
        defer { isDispatchingKey = false }
        try body()
    }

    @objc func run(_ sender: NSMenuItem) {
        ran.append(sender.title)
        switch sender.title {
        case "Zoom In": percent += 10
        case "Zoom Out": percent -= 10
        case "Actual Size": percent = 100
        default: break
        }
    }
}
