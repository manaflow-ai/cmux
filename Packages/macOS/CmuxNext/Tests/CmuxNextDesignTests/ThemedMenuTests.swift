import AppKit
import CmuxTheme
@testable import CmuxNextDesign
import Testing

/// Follow-up to #19754: the workspace, tab and pane right-click menus highlight their rows in the
/// theme's accent, not macOS's. NSMenu draws its highlight in the system accent whatever the
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

    @Test func aHighlightedRowDrawsTheThemeAccentNotTheSystemAccent() throws {
        let scope = try Self.accentedScope()
        let counter = Counter()
        let menu = Self.menu(counter)
        menu.themeRows(in: scope)

        let row = try #require(menu.items[0].view as? ThemedMenuRowView, "the row is cmux-drawn")
        row.highlightOverride = true
        let fill = try #require(Self.sample(row, x: 8))
        let accent = scope.tokens.accent.withAlpha(1).nsColor
        #expect(Self.distance(fill, accent) < 0.04, "highlight \(fill) vs theme accent \(accent)")
        for system in [NSColor.controlAccentColor, .selectedContentBackgroundColor] {
            #expect(Self.distance(fill, system) > 0.15, "highlight \(fill) is the system accent \(system)")
        }

        // An unhighlighted row paints no fill there.
        row.highlightOverride = false
        let plain = try #require(Self.sample(row, x: 8))
        #expect(plain.alphaComponent < 0.05 || Self.distance(plain, accent) > 0.15)

        // The ink on the highlight reads: the theme's on-accent, at least 4.5:1.
        let tokens = scope.tokens
        #expect(tokens.onAccent.withAlpha(1).contrast(with: tokens.accent.withAlpha(1)) >= ThemeTokens.minimumTextContrast)
        #expect(Self.distance(scope.perform { Palette.onAccent }, tokens.onAccent.withAlpha(1).nsColor) < 0.02)
        #expect(Self.distance(scope.perform { Palette.accentFill }, accent) < 0.02)
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
