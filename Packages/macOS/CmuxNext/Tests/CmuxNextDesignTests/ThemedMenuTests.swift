import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Follow-up to #19754: the workspace, tab and pane right-click menus highlight their rows with a
/// wash of the theme's accent, not macOS's. NSMenu draws its highlight in the system accent whatever the
/// theme, so these menus' rows are cmux-drawn (`NSMenu.themeRows(in:)`), and a drawn row must still run its
/// action once from a click and from Return.
@MainActor @Suite(.serialized) struct ThemedMenuTests {
    /// A dark theme with its own orange accent: far from any system accent.
    private static func accentedScope() throws -> ThemeScope {
        var input = ThemeInput(background: ThemeRGB(hex: 0x1C1B22), foreground: ThemeRGB(hex: 0xE8E4F0))
        input.accentColor = ThemeRGB(hex: 0xE5813A)
        let scope = ThemeScope(level: .room)
        scope.setOverride(ThemeSpec("Menu Orange"), input: input, animated: false)
        return scope
    }

    /// The highlight is a faint wash of the theme's accent over the menu's glass, never a solid bar
    /// and never the system blue (Leo 2026-10-20: "the blue is garish, but don't make it opaque").
    @Test func aHighlightedRowWashesTheThemeAccentNotTheSystemAccent() throws {
        let scope = try Self.accentedScope()
        let counter = Counter()
        let menu = Self.menu(counter)
        menu.themeRows(in: scope)

        let row = try #require(menu.items[0].view as? ThemedMenuRowView, "the row is cmux-drawn")
        row.highlightOverride = true
        let fill = try #require(Self.sample(row, x: 8))
        let accent = scope.tokens.accent.withAlpha(1).nsColor
        #expect(fill.alphaComponent > 0.1 && fill.alphaComponent < 0.35, "highlight alpha \(fill.alphaComponent) is a wash, not a bar")
        let hue = try #require(fill.withAlphaComponent(1).usingColorSpace(.sRGB))
        #expect(Self.distance(hue, accent) < 0.06, "highlight \(hue) vs theme accent \(accent)")
        for system in [NSColor.controlAccentColor, .selectedContentBackgroundColor] {
            #expect(Self.distance(hue, system) > 0.15, "highlight \(hue) is the system accent \(system)")
        }

        // An unhighlighted row paints no fill there.
        row.highlightOverride = false
        let plain = try #require(Self.sample(row, x: 8))
        #expect(plain.alphaComponent < 0.05)
    }

    @Test func returnRunsTheActionOnce() throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        menu.themeRows(in: try Self.accentedScope())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)
        row.highlightOverride = true

        // AppKit's Return on the highlighted item sends the item's action; the row also takes
        // Return itself. One press runs the action once, whichever reaches it first.
        menu.performActionForItem(at: 0)
        #expect(row.performKeyEquivalent(with: try Self.returnKey()))
        // The row's run waits for the menu's tracking loop to end: let it.
        Self.drainRunLoop { false }
        #expect(counter.count == 1)
        #expect(counter.sender === menu.items[0], "the action gets its own item, which carries its payload")
    }

    @Test func aClickRunsTheActionOnce() throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        menu.themeRows(in: try Self.accentedScope())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)

        let point = NSPoint(x: 30, y: row.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            type == .leftMouseDown ? row.mouseDown(with: event) : row.mouseUp(with: event)
        }
        // Like a native row, the action runs once the menu's tracking loop has ended.
        #expect(counter.count == 0)
        Self.drainRunLoop { counter.count > 0 }
        #expect(counter.count == 1)
        // The second row, never clicked, did not run.
        #expect(counter.sender === menu.items[0])
    }

    /// Code after `popUp` that settles the menu's outcome runs after the chosen row has run
    /// (a page menu ends a dismissed request only then; ending it first dropped every engine row).
    @Test func afterThemedRowRunsComesAfterTheChosenRow() throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        menu.themeRows(in: try Self.accentedScope())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)
        let point = NSPoint(x: 30, y: row.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            type == .leftMouseDown ? row.mouseDown(with: event) : row.mouseUp(with: event)
        }
        var seen: Int?
        menu.afterThemedRowRuns { seen = counter.count }
        Self.drainRunLoop { seen != nil }
        #expect(seen == 1, "the outcome step saw \(String(describing: seen)) runs of the chosen row")
    }

    /// Return, keypad Enter and Space on the highlighted row run it, as on a native menu (a real
    /// menu on cmux-macmini, 2026-10-21: Return and Enter did nothing on any themed row). A menu's
    /// window sends a key to its first responder and keeps it for itself when it has none, and the
    /// menu runs no action for a row drawn by a view. So the key goes the way a tracking menu sends it
    /// here: the menu's delegate hears the highlight, then the row's window gets the key.
    @Test(arguments: [(UInt16(36), "\r"), (UInt16(76), "\u{3}"), (UInt16(49), " ")])
    func anActivationKeyThroughTheMenusWindowRunsTheHighlightedRow(_ keyCode: UInt16, _ characters: String) throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        menu.themeRows(in: try Self.accentedScope())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)
        let window = Self.menuWindow(holding: row)
        row.highlightOverride = true
        // The pointer or an arrow key highlighted the first row.
        menu.delegate?.menu?(menu, willHighlight: menu.items[0])

        window.sendEvent(try Self.key(keyCode, characters, in: window))
        Self.drainRunLoop { counter.count > 0 }
        #expect(counter.count == 1, "key \(keyCode) on the highlighted row ran it \(counter.count) times; first responder \(String(describing: window.firstResponder))")
        #expect(counter.sender === menu.items[0])
    }

    /// A key chosen while the menu is open runs the row only once the menu has closed (a real menu on
    /// cmux-macmini, 2026-10-21: Return ran Mute Tab but Split Right and New Browser Tab did nothing,
    /// while a click on them worked). Until its root's `menuDidClose` the menu's window has the keys,
    /// so an action that acts on the focused window or pane would act on the menu. Code after
    /// `popUp` that settles the menu's outcome (`afterThemedRowRuns`) still runs after the row.
    @Test func aKeyRunsTheRowOnlyAfterTheMenuHasClosed() throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        menu.themeRows(in: try Self.accentedScope())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)
        let window = Self.menuWindow(holding: row)
        row.highlightOverride = true
        menu.delegate?.menuWillOpen?(menu)
        menu.delegate?.menu?(menu, willHighlight: menu.items[0])

        window.sendEvent(try Self.key(36, "\r", in: window))
        var settled: Int?
        menu.afterThemedRowRuns { settled = counter.count }
        Self.drainRunLoop { counter.count > 0 }
        #expect(counter.count == 0, "the row ran while its menu was still open")
        #expect(settled == nil, "the outcome step ran before the chosen row")

        menu.delegate?.menuDidClose?(menu)
        Self.drainRunLoop { counter.count > 0 && settled != nil }
        #expect(counter.count == 1)
        #expect(counter.sender === menu.items[0], "the action gets its own item, which carries its target")
        #expect(settled == 1, "the outcome step saw \(String(describing: settled)) runs of the chosen row")
    }

    /// Any other key on the highlighted row is the menu's (arrows, Right into a submenu,
    /// type-select, Escape): the row runs nothing and gives up the keys, so the menu's window
    /// handles the key as its own.
    @Test func anotherKeyOnTheHighlightedRowGoesBackToTheMenu() throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        menu.themeRows(in: try Self.accentedScope())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)
        let window = Self.menuWindow(holding: row)
        row.highlightOverride = true
        menu.delegate?.menu?(menu, willHighlight: menu.items[0])
        #expect(window.firstResponder === row, "the highlighted row has the menu's keys")

        for (code, characters) in [(UInt16(125), "\u{F701}"), (UInt16(124), "\u{F703}"), (UInt16(15), "r")] {
            menu.delegate?.menu?(menu, willHighlight: menu.items[0])
            window.sendEvent(try Self.key(code, characters, in: window))
            #expect(window.firstResponder !== row, "key \(code) stayed with the row")
        }
        Self.drainRunLoop { counter.count > 0 }
        #expect(counter.count == 0)
    }

    /// A field in the menu that has the keys (the identity header's name) keeps them while the
    /// pointer passes over the rows.
    @Test func aFieldWithTheKeysKeepsThemWhileRowsHighlight() throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        menu.themeRows(in: try Self.accentedScope())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)
        let window = Self.menuWindow(holding: row)
        let field = NSTextField(string: "Name")
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        let editor = window.firstResponder
        menu.delegate?.menu?(menu, willHighlight: menu.items[0])
        #expect(window.firstResponder === editor, "a highlighted row took the keys from the name field")
    }

    /// Return on a highlighted submenu row is AppKit's (it opens the submenu): the row passes it on.
    @Test func returnOnASubmenuRowIsNotSwallowed() throws {
        let counter = Counter()
        let menu = NSMenu()
        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        more.submenu = Self.menu(counter)
        menu.addItem(more)
        menu.themeRows(in: try Self.accentedScope())
        let row = try #require(menu.items[0].view as? ThemedMenuRowView)
        row.highlightOverride = true
        #expect(row.performKeyEquivalent(with: try Self.returnKey()) == false)
        #expect(counter.count == 0)
    }

    /// Arrow keys move the highlight; the rows losing and taking it redraw, and a submenu's own
    /// delegate (a choices coordinator's preview) still hears the highlight.
    @Test func aHighlightChangeRedrawsRowsAndReachesTheMenusDelegate() throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        let spy = DelegateSpy()
        menu.delegate = spy
        menu.themeRows(in: try Self.accentedScope())
        let row = try #require(menu.items[1].view as? ThemedMenuRowView)
        let other = try #require(menu.items[0].view as? ThemedMenuRowView)
        menu.delegate?.menu?(menu, willHighlight: menu.items[1])
        #expect(row.highlightChanges == 1, "the row taking the highlight redraws")
        #expect(other.highlightChanges == 0)
        #expect(spy.highlighted === menu.items[1])
        menu.delegate?.menuDidClose?(menu)
        #expect(spy.closed)
    }

    @Test func keepsTitlesSubmenusAndValidation() throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        let more = NSMenuItem(title: "More", action: nil, keyEquivalent: "")
        more.submenu = Self.menu(counter)
        menu.addItem(more)
        menu.themeRows(in: try Self.accentedScope())

        // Type-select and VoiceOver read the item's title; the submenu still opens from its row.
        #expect(menu.items.map(\.title) == ["Rename", "Close", "More"])
        #expect(menu.items[2].submenu?.items.first?.view is ThemedMenuRowView)
        // Disabled stays disabled: validation still reaches the action's own target.
        counter.enabled = false
        menu.update()
        #expect(menu.items[0].isEnabled == false)
        counter.enabled = true
        menu.update()
        #expect(menu.items[0].isEnabled)
    }

    /// A submenu its delegate fills as it opens (Open With ▸) themes the rows it just added.
    @Test func rowsAddedAsASubmenuOpensAreThemed() throws {
        let counter = Counter()
        let menu = Self.menu(counter)
        let openWith = NSMenuItem(title: "Open With", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Open With")
        let filler = Filler(counter)
        submenu.delegate = filler
        openWith.submenu = submenu
        menu.addItem(openWith)
        menu.themeRows(in: try Self.accentedScope())

        #expect(submenu.items.isEmpty)
        submenu.delegate?.menuNeedsUpdate?(submenu)
        #expect(filler.updates == 1, "the menu's own delegate still fills it")
        let row = try #require(submenu.items.first)
        #expect(row.view is ThemedMenuRowView, "the added row is cmux-drawn")
    }

    // MARK: Helpers

    private static func menu(_ counter: Counter) -> NSMenu {
        _ = NSApplication.shared
        let menu = NSMenu()
        for (title, key) in [("Rename", ""), ("Close", "w")] {
            let item = NSMenuItem(title: title, action: #selector(Counter.fire(_:)), keyEquivalent: key)
            item.target = counter
            menu.addItem(item)
        }
        return menu
    }

    /// Runs the main run loop in its default mode until `done` or a short deadline.
    private static func drainRunLoop(until done: () -> Bool) {
        let deadline = Date(timeIntervalSinceNow: 0.5)
        while !done(), Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.02))
        }
    }

    /// A window that holds `row` as a menu's window holds its rows (never shown).
    private static func menuWindow(holding row: NSView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 60), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(row)
        return window
    }

    private static func key(_ keyCode: UInt16, _ characters: String, in window: NSWindow) throws -> NSEvent {
        let flags: NSEvent.ModifierFlags = keyCode == 76 ? [.numericPad] : []
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                                             keyCode: keyCode))
    }

    private static func returnKey() throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
    }

    private static func sample(_ view: NSView, x: CGFloat) -> NSColor? {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / view.bounds.width
        return rep.colorAt(x: Int(x * scale), y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }

    private static func distance(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        guard let lhs = lhs.usingColorSpace(.sRGB), let rhs = rhs.usingColorSpace(.sRGB) else { return .infinity }
        return max(abs(lhs.redComponent - rhs.redComponent), abs(lhs.greenComponent - rhs.greenComponent),
                   abs(lhs.blueComponent - rhs.blueComponent))
    }
}

/// An action target that counts its runs and validates as `enabled` says.
@MainActor private final class Counter: NSObject, NSMenuItemValidation {
    var count = 0
    var enabled = true
    weak var sender: NSMenuItem?

    @objc func fire(_ sender: NSMenuItem) {
        count += 1
        self.sender = sender
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { enabled }
}

/// A menu delegate that records what it heard.
@MainActor private final class DelegateSpy: NSObject, NSMenuDelegate {
    weak var highlighted: NSMenuItem?
    var closed = false

    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) { highlighted = item }
    func menuDidClose(_ menu: NSMenu) { closed = true }
}

/// A submenu delegate that adds one row each time the submenu opens.
@MainActor private final class Filler: NSObject, NSMenuDelegate {
    private let counter: Counter
    var updates = 0

    init(_ counter: Counter) { self.counter = counter }

    func menuNeedsUpdate(_ menu: NSMenu) {
        updates += 1
        menu.removeAllItems()
        let item = NSMenuItem(title: "TextEdit", action: #selector(Counter.fire(_:)), keyEquivalent: "")
        item.target = counter
        menu.addItem(item)
    }
}
