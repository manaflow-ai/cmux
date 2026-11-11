import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// The space switcher may hint at the spaces other windows show, and a click on any space shows it in this window,
/// taking it from the window that showed it (design/spaces.md "The switcher (PR 3)", `sidebar.spaceSwitcher`). Leo
/// 2026-11-11: "we wanted the different windows to be accessible through spaces, and it's essentially all the same
/// window in a way if you want it to be". Incognito never mixes with normal content.
@MainActor @Suite(.serialized, .closesItsWindows) struct SpaceSwitcherWindowMarksTests {
    static let keys = (0..<3).map { ProfileKey("space\($0)") }

    // MARK: Which spaces other windows show

    @Test func otherWindowsSpacesAreListedWithTheFrontmostWindow() {
        let windows = [
            SpaceWindowShowing(windowID: "front", space: Self.keys[1]),
            SpaceWindowShowing(windowID: "here", space: Self.keys[0]),
            SpaceWindowShowing(windowID: "back", space: Self.keys[1]),
            SpaceWindowShowing(windowID: "incognito", space: Self.keys[2], incognito: true),
        ]
        let shown = SpaceSwitcherLogic.shownElsewhere(windows, here: "here")
        #expect(shown[Self.keys[0]] == nil, "this window's own space is not elsewhere")
        #expect(shown[Self.keys[1]] == SpaceElsewhere(windowID: "front", incognito: false), "the frontmost window wins")
        #expect(shown[Self.keys[2]] == SpaceElsewhere(windowID: "incognito", incognito: true))
    }

    @Test func aSpaceThisWindowAlsoShowsIsStillMarkedWhenAnotherWindowShowsIt() {
        let shown = SpaceSwitcherLogic.shownElsewhere([SpaceWindowShowing(windowID: "here", space: Self.keys[0]),
                                                       SpaceWindowShowing(windowID: "other", space: Self.keys[0])], here: "here")
        #expect(shown[Self.keys[0]]?.windowID == "other")
    }

    /// Every style switches this window: another normal window's space comes here, this window's own space too when
    /// another window also shows it. Incognito never mixes: it takes the plain switch (whose rule shows its window).
    @Test func aClickBringsTheSpaceHereInEveryStyle() {
        let other = SpaceElsewhere(windowID: "w", incognito: false), incognito = SpaceElsewhere(windowID: "w", incognito: true)
        func click(_ style: SpaceSwitcherStyle, _ space: ProfileKey, elsewhere: SpaceElsewhere? = other, hereIsIncognito: Bool = false) -> SpaceClick {
            SpaceSwitcherLogic.click(space, active: Self.keys[0], elsewhere: elsewhere, hereIsIncognito: hereIsIncognito, style: style)
        }
        for style in [SpaceSwitcherStyle.ring, .glyph, .plain] {
            #expect(click(style, Self.keys[1]) == .pullHere, "\(style)")
            #expect(click(style, Self.keys[0]) == .pullHere, "\(style): the current space another window also shows")
            #expect(click(style, Self.keys[1], elsewhere: nil) == .switchHere, "\(style)")
            #expect(click(style, Self.keys[0], elsewhere: nil) == SpaceClick.none, "\(style)")
            #expect(click(style, Self.keys[1], elsewhere: incognito) == .switchHere, "\(style): an incognito space never moves")
            #expect(click(style, Self.keys[1], hereIsIncognito: true) == .switchHere, "\(style): nothing moves into incognito")
        }
        #expect(click(.menu, Self.keys[0]) == .spaceMenu)
        #expect(click(.menu, Self.keys[1]) == .pullHere)
        #expect(SpaceSwitcherStyle.tunable.defaultValue == .ring, "the gallery's pick is the default for the hint only")
    }

    // MARK: The bar

    final class Bar {
        let model = SidebarModel()
        let view: ProfileBarView
        let window: NSWindow
        var intents: [SidebarIntent] = []
        var actions: [SpaceWindowAction] = []
        var menus: [NSMenu] = []
        var opens: [Bool] = []
        /// The mark lit while its menu was open.
        var litWhileOpen: Int?

        init(style: SpaceSwitcherStyle) {
            model.profiles = SpaceSwitcherWindowMarksTests.keys.enumerated().map { SidebarProfile(id: $1, name: "Space \($0)") }
            model.activeProfileID = SpaceSwitcherWindowMarksTests.keys[0]
            view = ProfileBarView(model: model)
            view.windowMarks.elsewhere = [SpaceSwitcherWindowMarksTests.keys[1]: SpaceElsewhere(windowID: "other", incognito: false)]
            view.switcherStyleOverride = style
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 28), styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            view.frame = NSRect(x: 0, y: 0, width: 240, height: 28)
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            view.refresh()
            model.onIntent = { [weak self] intent in self?.intents.append(intent) }
            view.windowMarks.perform = { [weak self] action in self?.actions.append(action) }
            view.onMenuOpenChange = { [weak self] open in self?.opens.append(open) }
            view.presentMenu = { [weak self] menu, _ in
                guard let self else { return }
                self.menus.append(menu)
                self.view.setHovered(nil) // the pointer leaves while the menu is open
                self.litWhileOpen = self.view.hovered
            }
        }

        func click(_ index: Int) {
            let slot = view.slotRects()[index], point = NSPoint(x: slot.midX, y: slot.midY)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                                   eventNumber: 0, clickCount: 1, pressure: 1)!
            }
            view.mouseDown(with: event(.leftMouseDown))
            view.mouseUp(with: event(.leftMouseUp))
        }

        func choose(_ title: String, in menu: NSMenu) {
            (menu.items.first { $0.title == title } as? SwitcherMenuItem)?.fire()
        }
    }

    /// Leo 2026-11-11: "we wanted the different windows to be accessible through spaces". A click on another window's
    /// space brings it here: no menu, no other window raised.
    @Test func clickingAnotherWindowsSpaceBringsItHere() {
        let bar = Bar(style: .ring)
        defer { bar.window.closeAfterTest() }
        bar.click(1)
        #expect(bar.menus.isEmpty, "a menu opened")
        #expect(bar.actions == [.moveHere(Self.keys[1])] && bar.intents.isEmpty, "\(bar.actions) \(bar.intents)")
    }

    /// The `plain` style draws no hint and still brings the space here: the hint is drawing only.
    @Test func thePlainStripAlsoBringsTheSpaceHere() {
        let bar = Bar(style: .plain)
        defer { bar.window.closeAfterTest() }
        bar.click(1)
        #expect(bar.actions == [.moveHere(Self.keys[1])] && bar.intents.isEmpty && bar.menus.isEmpty)
    }

    @Test func aSpaceNoOtherWindowShowsSwitches() {
        let ring = Bar(style: .ring), plain = Bar(style: .plain)
        defer { ring.window.closeAfterTest(); plain.window.closeAfterTest() }
        ring.click(2)
        plain.click(2)
        #expect(ring.intents == [.switchProfile(Self.keys[2])] && ring.menus.isEmpty && ring.actions.isEmpty)
        #expect(plain.intents == [.switchProfile(Self.keys[2])] && plain.menus.isEmpty && plain.actions.isEmpty)
    }

    /// An incognito space lives in its own window (design rule 2): the click is the plain switch, never a move.
    @Test func anIncognitoSpaceIsNeverMoved() {
        let bar = Bar(style: .ring)
        defer { bar.window.closeAfterTest() }
        bar.view.windowMarks.elsewhere = [Self.keys[1]: SpaceElsewhere(windowID: "incognito", incognito: true)]
        bar.click(1)
        #expect(bar.actions.isEmpty && bar.intents == [.switchProfile(Self.keys[1])] && bar.menus.isEmpty)
    }

    @Test func theSpaceMenuNamesEverySpaceAndBringsItHere() throws {
        let bar = Bar(style: .menu)
        defer { bar.window.closeAfterTest() }
        bar.click(0)
        let menu = try #require(bar.menus.first)
        let titles = menu.items.filter { !$0.isSeparatorItem }.map(\.title)
        #expect(titles == ["Space 0", "Space 1", "Space 2", Strings.newProfile, Strings.newIncognitoSpace])
        #expect(menu.items[0].state == .on, "the current space is not checked")
        #expect(menu.items.allSatisfy { $0.submenu == nil }, "a row still opens window choices")
        bar.choose("Space 1", in: menu)
        bar.choose("Space 2", in: menu)
        bar.choose(Strings.newIncognitoSpace, in: menu)
        #expect(bar.intents == [.switchProfile(Self.keys[2])])
        #expect(bar.actions == [.moveHere(Self.keys[1]), .newIncognitoSpace])
    }

    /// Leo 2026-11-11: "Wait, why does it say default in another window?" The tooltip and the VoiceOver label are the
    /// space's name alone, wherever it is shown.
    @Test func theMarkNamesTheSpaceAlone() {
        let bar = Bar(style: .ring)
        defer { bar.window.closeAfterTest() }
        bar.view.windowMarks.elsewhere[Self.keys[0]] = SpaceElsewhere(windowID: "other", incognito: false)
        bar.view.refresh()
        let labels = (bar.view.accessibilityChildren() ?? []).compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        #expect(labels.contains("Space 1") && labels.contains("Space 2"), "\(labels)")
        #expect(labels.contains(Strings.profileCurrent("Space 0")), "\(labels)")
        #expect(!labels.contains { $0.localizedCaseInsensitiveContains("window") }, "\(labels)")
        #expect(bar.view.spaceToolTips[1] == "Space 1" && bar.view.spaceToolTips[0] == "Space 0", "\(bar.view.spaceToolTips)")
    }
}
