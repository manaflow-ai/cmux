import AppKit
@testable import CmuxNextFloating
import Foundation
import Observation
import Testing

/// The Chief pet: a non-activating panel over every app and Space that keeps
/// its spot per screen, stays fully on screen, tells a click from a drag, and
/// shows only while it is turned on.
@MainActor @Suite(.serialized) struct ChiefPetTests {
    @Observable final class Flag {
        var on: Bool
        init(_ on: Bool) { self.on = on }
    }

    static func defaults() -> UserDefaults {
        let name = "ChiefPetTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static let visible = CGRect(x: 0, y: 25, width: 1440, height: 850)
    static let size = ChiefPetPanel.petSize

    @Test func firstSpotIsTheBottomRightCorner() {
        let frame = ChiefPetPlacement.frame(saved: nil, size: Self.size, in: Self.visible)
        #expect(frame.maxX == Self.visible.maxX - ChiefPetPlacement.inset)
        #expect(frame.minY == Self.visible.minY + ChiefPetPlacement.inset)
        #expect(frame.size == Self.size)
    }

    @Test func savedSpotComesBackPerDisplay() {
        let placement = ChiefPetPlacement(defaults: Self.defaults())
        placement.save(CGPoint(x: 300, y: 400), onDisplay: "1")
        placement.save(CGPoint(x: 10, y: 40), onDisplay: "2")
        #expect(placement.origin(onDisplay: "1") == CGPoint(x: 300, y: 400))
        #expect(placement.origin(onDisplay: "2") == CGPoint(x: 10, y: 40))
        #expect(placement.origin(onDisplay: "3") == nil)
        let frame = ChiefPetPlacement.frame(saved: placement.origin(onDisplay: "1"), size: Self.size, in: Self.visible)
        #expect(frame.origin == CGPoint(x: 300, y: 400))
    }

    @Test func spotOffScreenIsPulledBackFullyOnScreen() {
        // Saved on a larger display, or past the menu bar and the Dock.
        for saved in [CGPoint(x: 5000, y: 5000), CGPoint(x: -200, y: -200), CGPoint(x: 1430, y: 0)] {
            let frame = ChiefPetPlacement.frame(saved: saved, size: Self.size, in: Self.visible)
            #expect(Self.visible.contains(frame), "\(saved) -> \(frame)")
        }
    }

    @Test func smallMovesAreClicksNotDrags() {
        let start = CGPoint(x: 100, y: 100)
        #expect(!ChiefPetPlacement.isDrag(from: start, to: CGPoint(x: 101, y: 102)))
        #expect(ChiefPetPlacement.isDrag(from: start, to: CGPoint(x: 103, y: 100)))
        #expect(ChiefPetPlacement.isDrag(from: start, to: CGPoint(x: 90, y: 120)))
    }

    @Test func panelFloatsOverEveryAppWithoutTakingFocus() {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.level == .floating)
        #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(panel.collectionBehavior.contains(.ignoresCycle))
        #expect(panel.accessibilityIdentifier() == ChiefPetPanel.accessibilityID)
        #expect(panel.pet.acceptsFirstMouse(for: nil))
    }

    /// ⌃⌥⌘C (Message the Chief from Any App) orders the pet in without unhiding cmux. With cmux
    /// hidden (⌘H, Hide Others), a window that hides with its app would stay hidden; the pet, its
    /// notices and its reply box don't hide with the app, so they show without bringing back
    /// every main window.
    @Test func petNoticesAndReplyBoxStayOutWhileCmuxIsHidden() {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        #expect(!panel.canHide)
        #expect(!ChiefPetBubblePanel().canHide)
        let reply = ChiefPetReplyPanel()
        #expect(!reply.canHide)
        #expect(!reply.hidesOnDeactivate)
    }

    /// A notice is the toasts' neutral glass (a veil and rim over the glass), not bare glass, whose
    /// text a web page's headline showed through, and never the mostly opaque card fill: glass stays
    /// glass (Leo 2026-10-20: "I hate opaque").
    @Test func noticeCapsuleIsTheToastsGlassNeverOpaque() {
        let capsule = ChiefPetCapsule(frame: NSRect(x: 0, y: 0, width: ChiefPetBubblePanel.width, height: ChiefPetBubblePanel.pillHeight))
        #expect(capsule.surface.tone.style == .toast, "the toasts' veil keeps its text legible")
        #expect(!capsule.surface.isCard, "no opaque card fill on the glass")
        #expect(capsule.surface.samplesBehindWindow, "the blur before macOS 26 samples what is behind its clear window")
        #expect(capsule.surface.cornerRadius == ChiefPetBubblePanel.pillHeight / 2)
    }

    /// One press through the view: down at `from`, dragged through `path`, up.
    /// `onCharacter` false presses the rail's background instead.
    private func press(_ pet: ChiefPetView, from: CGPoint, path: [CGPoint], onCharacter: Bool = true) {
        var pointer = from
        pet.pointer = { pointer }
        pet.layoutSubtreeIfNeeded()
        let spot = onCharacter ? CGPoint(x: pet.characterFrame.midX, y: pet.characterFrame.midY) : CGPoint(x: 2, y: 2)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: pet.convert(spot, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: pet.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        pet.mouseDown(with: event)
        for point in path {
            pointer = point
            pet.mouseDragged(with: event)
        }
        pet.mouseUp(with: event)
    }

    @Test func clickRunsOnClickAndDoesNotMove() {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        var clicks = 0
        var drags = 0
        panel.onClick = { clicks += 1 }
        panel.pet.onDragEnded = { drags += 1 }
        press(panel.pet, from: CGPoint(x: 220, y: 230), path: [CGPoint(x: 221, y: 231)])
        #expect(clicks == 1)
        #expect(drags == 0)
        #expect(panel.frame.origin == CGPoint(x: 200, y: 200))
    }

    @Test func dragMovesThePanelWithThePointerAndIsNotAClick() {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        var clicks = 0
        var drags = 0
        panel.onClick = { clicks += 1 }
        panel.pet.onDragEnded = { drags += 1 }
        press(panel.pet, from: CGPoint(x: 220, y: 230), path: [CGPoint(x: 240, y: 230), CGPoint(x: 320, y: 180)])
        #expect(clicks == 0)
        #expect(drags == 1)
        #expect(panel.frame.origin == CGPoint(x: 300, y: 150))
    }

    @Test func everyMascotIsBundled() {
        for mascot in ChiefPetMascot.allCases {
            #expect(mascot.image != nil, "\(mascot.rawValue) (\(mascot.resource))")
        }
        #expect(ChiefPetMascot.initial == .orb, "the Chief Dock's default")
        #expect(ChiefPetMascot.orbSpark.resource == "ChiefMascotOrbSpark")
    }

    @Test func everySettingIdIsAMascot() {
        // HomeChiefPetSetting.mascots (CmuxNextSettings) lists the same ids.
        #expect(ChiefPetMascot.allCases.map(\.rawValue) == ["orb", "orb-spark", "orb-hood", "machine", "machine-cyan", "machine-blue", "moon", "moon-blue", "fox", "mochi"])
    }

    @Test func pressOnTheRailBackgroundDragsButIsNoClick() {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        var clicks = 0
        panel.onClick = { clicks += 1 }
        press(panel.pet, from: CGPoint(x: 210, y: 205), path: [], onCharacter: false)
        #expect(clicks == 0)
        press(panel.pet, from: CGPoint(x: 210, y: 205), path: [CGPoint(x: 260, y: 205)], onCharacter: false)
        #expect(panel.frame.origin == CGPoint(x: 250, y: 200), "the rail's background drags the pet too")
    }

    @Test func composeOnTheRailOpens() throws {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        var clicks = 0
        panel.onClick = { clicks += 1 }
        panel.pet.layoutSubtreeIfNeeded()
        let tool = try #require(panel.pet.rail.subviews.flatMap(\.subviews).compactMap { $0 as? ChiefPetTool }.first)
        tool.performClick(nil)
        #expect(clicks == 1)
    }

    /// The pet's right-click menu: Chief Pet Settings… closes the reply box and opens the
    /// settings; Hide Chief Pet hides it (the App turns `home.chiefPetEnabled` off).
    @Test func rightClickMenuOpensSettingsAndHides() throws {
        let defaults = Self.defaults()
        var settings = 0, hides = 0
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { _ in }, send: { _, _ in true },
                                                                     openSettings: { settings += 1 }, hide: { hides += 1 }))
        controller.sync(true)
        let panel = try #require(controller.panel)
        let menu = panel.contextMenu()
        #expect(menu.items.map(\.title) == [ChiefPetStrings.settings, ChiefPetStrings.hide])
        panel.onClick?()
        #expect(controller.replyPanel?.isVisible == true)
        for item in menu.items { _ = (item.target as AnyObject?)?.perform(item.action) }
        #expect(settings == 1)
        #expect(hides == 1)
        #expect(controller.replyPanel?.isVisible == false, "the settings come up without the reply box")
        controller.sync(false)
    }

    /// With `home.chiefPetEnabled` managed the App cannot hide the pet, so the menu greys out Hide.
    @Test func rightClickMenuGreysOutHideWhenItCannotHide() throws {
        let defaults = Self.defaults()
        var canHide = false
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }, canHide: { canHide }))
        controller.sync(true)
        let panel = try #require(controller.panel)
        #expect(panel.contextMenu().items.map(\.isEnabled) == [true, false])
        canHide = true
        #expect(panel.contextMenu().items.map(\.isEnabled) == [true, true])
        controller.sync(false)
    }

    /// The notices lay out toward the side of the screen with room (Leo 2026-10-20): from the pet's
    /// trailing edge leftward on the right half, from its leading edge rightward on the left half;
    /// above it on the lower half, below it on the upper half.
    @Test func noticesOpenTowardTheQuadrantWithRoom() {
        let size = Self.size
        let height = ChiefPetBubblePanel.height(count: 2, expanded: true)
        let gap = ChiefPetBubblePanel.gap
        let v = Self.visible
        let bottomRight = CGRect(origin: CGPoint(x: v.maxX - 24 - size.width, y: v.minY + 24), size: size)
        let bottomLeft = CGRect(origin: CGPoint(x: v.minX + 24, y: v.minY + 24), size: size)
        let topLeft = CGRect(origin: CGPoint(x: v.minX + 24, y: v.maxY - 24 - size.height), size: size)
        let topRight = CGRect(origin: CGPoint(x: v.maxX - 24 - size.width, y: v.maxY - 24 - size.height), size: size)

        let br = ChiefPetBubblePanel.frame(height: height, over: bottomRight, in: v)
        #expect(br.maxX == bottomRight.maxX, "right half: the trailing edges line up and the cards extend left")
        #expect(br.minY == bottomRight.maxY + gap, "lower half: above the pet")

        let bl = ChiefPetBubblePanel.frame(height: height, over: bottomLeft, in: v)
        #expect(bl.minX == bottomLeft.minX, "left half: the leading edges line up and the cards extend right")
        #expect(bl.minY == bottomLeft.maxY + gap)

        let tl = ChiefPetBubblePanel.frame(height: height, over: topLeft, in: v)
        #expect(tl.minX == topLeft.minX)
        #expect(tl.maxY == topLeft.minY - gap, "upper half: below the pet")

        let tr = ChiefPetBubblePanel.frame(height: height, over: topRight, in: v)
        #expect(tr.maxX == topRight.maxX)
        #expect(tr.maxY == topRight.minY - gap)

        for frame in [br, bl, tl, tr] {
            #expect(frame.width == ChiefPetBubblePanel.width)
            #expect(v.contains(frame), "\(frame) stays on screen")
        }
    }

    /// The reply box sits in the notices' place, so it takes their side.
    @Test func replyBoxTakesTheNoticesSide() {
        let v = Self.visible
        let topLeft = CGRect(origin: CGPoint(x: v.minX + 24, y: v.maxY - 24 - Self.size.height), size: Self.size)
        let reply = ChiefPetBubblePanel.frame(height: ChiefPetReplyPanel.size.height, over: topLeft, in: v,
                                              width: ChiefPetReplyPanel.size.width, gap: ChiefPetReplyPanel.gap)
        #expect(reply.minX == topLeft.minX)
        #expect(reply.maxY == topLeft.minY - ChiefPetReplyPanel.gap)
    }

    @Test func dragReportsEveryMoveBeforeItEnds() {
        let panel = ChiefPetPanel(defaults: Self.defaults())
        panel.setFrameOrigin(CGPoint(x: 200, y: 200))
        var moves: [CGPoint] = []
        var ended = 0
        panel.pet.onDragMoved = { moves.append(panel.frame.origin) }
        panel.pet.onDragEnded = { ended += 1 }
        press(panel.pet, from: CGPoint(x: 220, y: 230), path: [CGPoint(x: 221, y: 230), CGPoint(x: 240, y: 230), CGPoint(x: 320, y: 180)])
        #expect(moves == [CGPoint(x: 220, y: 200), CGPoint(x: 300, y: 150)], "a move under the slop is no drag yet")
        #expect(ended == 1)
    }

    /// Dragged across the screen's middle, the notices turn to the other side while the pet moves,
    /// so the drop moves nothing and nothing fades in again.
    @Test func noticesFollowTheDragLiveAndTheDropMovesNothing() throws {
        let defaults = Self.defaults()
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }))
        controller.sync(true)
        defer { controller.sync(false) }
        controller.arrive(ChiefPetNotice(id: 1, tab: "t", surface: nil, title: "Done", detail: "Build finished", kind: .done))
        let panel = try #require(controller.panel)
        let bubble = try #require(controller.bubble)
        let visible = Self.visible
        panel.visibleFrame = { visible }
        // Start on the lower right, then drag to the lower left.
        let start = CGPoint(x: visible.maxX - 40 - panel.frame.width, y: visible.minY + 40)
        panel.setFrameOrigin(start)
        controller.render(animated: false)
        #expect(bubble.frame.maxX == panel.frame.maxX)
        var pointer = CGPoint(x: start.x + 10, y: start.y + 10)
        panel.pet.pointer = { pointer }
        panel.pet.layoutSubtreeIfNeeded()
        let spot = CGPoint(x: panel.pet.characterFrame.midX, y: panel.pet.characterFrame.midY)
        let event = NSEvent.mouseEvent(with: .leftMouseDown, location: panel.pet.convert(spot, to: nil), modifierFlags: [], timestamp: 0,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        panel.pet.mouseDown(with: event)
        pointer.x -= visible.width / 2 + 200
        panel.pet.mouseDragged(with: event)
        #expect(panel.frame.midX < visible.midX)
        #expect(bubble.frame.minX == panel.frame.minX, "mid-drag the notices already open to the right")
        #expect(bubble.isVisible, "the notices stay up through the drag")
        let beforeDrop = bubble.frame
        panel.pet.mouseUp(with: event)
        #expect(bubble.frame == beforeDrop, "the drop does not move the notices")
        #expect(bubble.isVisible)
    }

    @Test func controllerShowsThePetOnlyWhileItIsOn() async {
        let flag = Flag(false)
        let defaults = Self.defaults()
        let controller = ChiefPetController(makePanel: { ChiefPetPanel(defaults: defaults) },
                                            actions: ChiefPetActions(open: { _ in }, send: { _, _ in true }))
        controller.start(enabled: { flag.on })
        for _ in 0..<100 { await Task.yield() }
        #expect(controller.panel == nil, "off: no panel is made")
        flag.on = true
        for _ in 0..<1000 where !controller.isShown { await Task.yield() }
        #expect(controller.isShown, "the setting turning on shows it")
        controller.panel?.onClick?()
        #expect(controller.replyPanel?.isVisible == true, "a click opens the reply box")
        let made = controller.panel
        flag.on = false
        for _ in 0..<1000 where controller.isShown { await Task.yield() }
        #expect(!controller.isShown)
        #expect(controller.replyPanel?.isVisible == false)
        flag.on = true
        for _ in 0..<1000 where !controller.isShown { await Task.yield() }
        // Made once: its spot and state are kept while it is hidden.
        #expect(controller.panel === made)
        controller.sync(false)
    }
}
