import AppKit
@testable import CmuxNextSidebar
import CmuxNextTestSupport
import Testing

/// Lawrence 2026-11-10: "make it so when i mousedown on switching space, it instantly switches". A press on a
/// space in the sidebar's space bar shows that space in the press's own turn, as a browser tab activates on
/// mouse-down; its release does nothing more. A press that then moves past the drag threshold drags the dot of
/// the now current space. What a click answers with a menu or with another window (a space another window
/// shows, the `menu` style's current space, Option-click's Go to Window) and the "+" still act on the release:
/// the dot stays draggable under the press, and a release off the mark cancels them. Real mouse events on the bar.
@MainActor @Suite(.serialized, .closesItsWindows) struct SpaceBarMouseDownSwitchTests {
    typealias Bar = ProfileBarDotReorderTests.Bar
    typealias MarkedBar = SpaceSwitcherWindowMarksTests.Bar
    static let keys = ProfileBarDotReorderTests.keys

    static func switches(_ intents: [SidebarIntent]) -> [SidebarIntent] {
        intents.filter { if case .switchProfile = $0 { true } else { false } }
    }

    // MARK: The press switches

    @Test func aPressOnAnotherSpaceShowsItBeforeTheRelease() {
        let bar = Bar()
        defer { bar.window.closeAfterTest() }
        let dot = bar.center(1)
        bar.view.mouseDown(with: bar.event(.leftMouseDown, dot))
        #expect(bar.intents == [.switchProfile(Self.keys[1])], "the press sent \(bar.intents): the space waits for the release")
        #expect(bar.model.activeProfileID == Self.keys[1], "the bar still shows \(String(describing: bar.model.activeProfileID)) while the button is down")
        bar.view.mouseUp(with: bar.event(.leftMouseUp, dot))
        #expect(bar.intents == [.switchProfile(Self.keys[1])], "the release acted again: \(bar.intents)")
        #expect(bar.model.activeProfileID == Self.keys[1])
    }

    /// The press already showed the space: a release off its dot neither takes it back nor acts on what is there.
    @Test func aReleaseOffTheDotKeepsThePressesSpace() {
        let bar = Bar()
        defer { bar.window.closeAfterTest() }
        let dot = bar.center(1), other = bar.center(2)
        bar.view.mouseDown(with: bar.event(.leftMouseDown, dot))
        bar.view.mouseUp(with: bar.event(.leftMouseUp, other))
        #expect(bar.intents == [.switchProfile(Self.keys[1])], "\(bar.intents)")
        #expect(bar.model.activeProfileID == Self.keys[1])
    }

    @Test func aPressOnTheCurrentSpaceSendsNothing() {
        let bar = Bar()
        defer { bar.window.closeAfterTest() }
        bar.drag(0, through: [])
        #expect(bar.intents.isEmpty, "\(bar.intents)")
        #expect(bar.model.activeProfileID == Self.keys[0])
    }

    // MARK: Press, then drag

    /// The press shows the space, then the drag moves that space's dot: one switch, one reorder, and the
    /// dragged space stays the current one.
    @Test func aPressOnAnotherSpaceThenADragMovesTheNowCurrentSpace() {
        let bar = Bar()
        defer { bar.window.closeAfterTest() }
        let dot = bar.center(2), first = bar.center(0)
        bar.view.mouseDown(with: bar.event(.leftMouseDown, dot))
        #expect(bar.model.activeProfileID == Self.keys[2], "the pressed space is not the current one when its drag starts")
        bar.view.mouseDragged(with: bar.event(.leftMouseDragged, NSPoint(x: dot.x - 6, y: first.y)))
        bar.view.mouseDragged(with: bar.event(.leftMouseDragged, NSPoint(x: first.x - 40, y: first.y)))
        #expect(bar.view.previewOrder == [Self.keys[2], Self.keys[0], Self.keys[1]], "the pressed dot does not drag")
        bar.view.mouseUp(with: bar.event(.leftMouseUp, NSPoint(x: first.x - 40, y: first.y)))
        #expect(bar.intents == [.switchProfile(Self.keys[2]), .reorderProfile(Self.keys[2], index: 0)], "\(bar.intents)")
        #expect(bar.order == [Self.keys[2], Self.keys[0], Self.keys[1]])
        #expect(bar.model.activeProfileID == Self.keys[2])
    }

    /// A dot dragged off the footer band springs back: the reorder is cancelled, the press's switch is not.
    @Test func aDragDroppedOffTheBandKeepsThePressesSpace() {
        let bar = Bar()
        defer { bar.window.closeAfterTest() }
        let dot = bar.center(1)
        bar.drag(1, through: [NSPoint(x: dot.x + 8, y: dot.y), NSPoint(x: dot.x + 8, y: dot.y - 200)])
        #expect(bar.reorders.isEmpty, "\(bar.intents)")
        #expect(Self.switches(bar.intents) == [.switchProfile(Self.keys[1])], "\(bar.intents)")
        #expect(bar.order == Self.keys)
    }

    // MARK: What still waits for the release

    /// As the app does: the space shows in the turn of the intent.
    private static func applyingIntents(_ bar: MarkedBar) {
        bar.model.onIntent = { [weak bar] intent in
            bar?.intents.append(intent)
            bar?.model.apply(intent)
            bar?.view.refresh()
        }
    }

    private static func event(_ type: NSEvent.EventType, at index: Int, in bar: MarkedBar, option: Bool = false) -> NSEvent {
        let slot = bar.view.slotRects()[index]
        return NSEvent.mouseEvent(with: type, location: bar.view.convert(NSPoint(x: slot.midX, y: slot.midY), to: nil),
                                  modifierFlags: option ? [.option] : [], timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: bar.window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Under the `menu` style a click on the current space opens the space menu. A press that switched made its
    /// space the current one: its release is the end of that press, not a click on the current space.
    @Test func theReleaseOfAPressThatSwitchedOpensNoSpaceMenu() {
        let bar = MarkedBar(style: .menu)
        defer { bar.window.closeAfterTest() }
        Self.applyingIntents(bar)
        bar.click(2)
        #expect(bar.intents == [.switchProfile(Self.keys[2])], "\(bar.intents)")
        #expect(bar.menus.isEmpty, "the release opened the space menu of the space its press just showed")
        // The next click, on the now current space, opens it.
        bar.click(2)
        #expect(bar.menus.count == 1)
    }

    /// A space another window shows answers a click with Go to Window / Move Here. The menu opens on the
    /// release: on the press its tracking would take the dot's drag.
    @Test func aSpaceAnotherWindowShowsOffersItsChoicesOnTheRelease() {
        let bar = MarkedBar(style: .ring)
        defer { bar.window.closeAfterTest() }
        Self.applyingIntents(bar)
        bar.view.mouseDown(with: Self.event(.leftMouseDown, at: 1, in: bar))
        #expect(bar.menus.isEmpty && bar.intents.isEmpty && bar.actions.isEmpty, "the press acted: \(bar.intents) \(bar.actions)")
        bar.view.mouseUp(with: Self.event(.leftMouseUp, at: 1, in: bar))
        #expect(bar.menus.count == 1 && bar.intents.isEmpty)
    }

    /// Option-click raises the window that shows the space: on the release, so a release off the mark cancels it.
    @Test func optionPressGoesToTheWindowOnTheRelease() {
        let bar = MarkedBar(style: .ring)
        defer { bar.window.closeAfterTest() }
        Self.applyingIntents(bar)
        bar.view.mouseDown(with: Self.event(.leftMouseDown, at: 1, in: bar, option: true))
        #expect(bar.actions.isEmpty && bar.intents.isEmpty, "the press acted: \(bar.intents) \(bar.actions)")
        bar.view.mouseUp(with: Self.event(.leftMouseUp, at: 1, in: bar, option: true))
        #expect(bar.actions == [.goToWindow(Self.keys[1])] && bar.intents.isEmpty && bar.menus.isEmpty)
    }

    /// The "+" makes a space on the release, as a button does.
    @Test func thePlusMakesASpaceOnTheRelease() {
        let bar = MarkedBar(style: .plain)
        defer { bar.window.closeAfterTest() }
        Self.applyingIntents(bar)
        let plus = bar.model.profiles.count
        bar.view.mouseDown(with: Self.event(.leftMouseDown, at: plus, in: bar))
        #expect(bar.intents.isEmpty, "\(bar.intents)")
        bar.view.mouseUp(with: Self.event(.leftMouseUp, at: plus, in: bar))
        #expect(bar.intents == [.newProfile], "\(bar.intents)")
    }
}
