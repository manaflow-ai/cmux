import AppKit
import CmuxNextActions
import CmuxNextBridge
@testable import CmuxNextApp
import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextFocusUI
import CmuxNextLayout
import CmuxNextTestSupport
import Foundation
import Observation
import Testing

/// The floating Chief's looks and moves (user 2026-11-07): "i want to be able to drag chief window around, we should
/// make global shortcut for it too"; "see how minimal it can get, since it will float everywhere"; every style drags
/// anywhere and remembers where it was left. Window events go through the window's `sendEvent`, as a person's do, so
/// the titlebar policy and hit testing are on the path.
@MainActor @Suite(.serialized, .closesItsWindows)
struct ChiefPanelStyleWindowTests {
    typealias Fixture = SidebarMultiViewWindowTests.Fixture

    /// A window showing `k1` with the floating Chief open (from a link), the Chief without the keys.
    static func openPanel(_ style: ChiefPanelStyle) async throws -> (Fixture, ChiefPanelView, NSView) {
        let (chief, _) = ChiefPanelWindowTests.chiefView()
        let f = try await ChiefPanelWindowTests.fixture(chief)
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.frame()
        let view = try #require(f.controller.chiefPanelView)
        view.style = style
        f.controller.focusStagePane(toward: nil) // the keys on the stage: a collapsing style rests
        f.controller.frameChiefPanelDidChange()
        f.frame()
        try #require(f.controller.frameChiefPanelShown, "the link opened no Chief")
        return (f, view, chief)
    }

    static func mouse(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    /// Presses the panel's grip and drags it by `delta` (window points, y up), as a hand does.
    static func drag(_ view: ChiefPanelView, by delta: CGVector, in f: Fixture) throws {
        let window = try #require(f.controller.window)
        let grip = view.convert(NSPoint(x: view.gripRect.midX, y: view.gripRect.midY), to: nil)
        #expect(TitlebarDragPolicy.decide(at: grip, in: window) == .staysPut, "a press on the grip moves the whole window")
        try #require(TitlebarDragPolicy.decide(at: grip, in: window) == .staysPut)
        let down = mouse(.leftMouseDown, at: grip, in: window)
        // A first click into a window that is not key (another window or app in front) must still drag.
        let frameView = try #require(window.contentView?.superview)
        let gripView = try #require(frameView.hitTest(frameView.convert(grip, from: nil)))
        #expect(gripView.acceptsFirstMouse(for: down), "a first click on the grip only makes the window key")
        window.sendEvent(down)
        for step in 1...4 {
            let t = CGFloat(step) / 4
            window.sendEvent(mouse(.leftMouseDragged, at: NSPoint(x: grip.x + delta.dx * t, y: grip.y + delta.dy * t), in: window))
        }
        window.sendEvent(mouse(.leftMouseUp, at: NSPoint(x: grip.x + delta.dx, y: grip.y + delta.dy), in: window))
        f.frame()
    }

    /// Every style drags by its grip from where it rests, lands where it was let go, and comes back there after a
    /// hide and a reopen. The first drag starts at the default place (the panel's bar lies in the titlebar row).
    @Test(arguments: ChiefPanelStyle.allCases)
    func everyStyleDragsAndRemembersWhereItWasLeft(_ style: ChiefPanelStyle) async throws {
        let (f, view, _) = try await Self.openPanel(style)
        defer { f.close() }
        let start = view.frame
        let savedBefore = f.state.chiefPanel.floatingFrame
        try Self.drag(view, by: CGVector(dx: -420, dy: -20), in: f)
        #expect(abs(view.frame.minX - (start.minX - 420)) <= 1 && abs(view.frame.minY - (start.minY - 20)) <= 1,
                "\(style): the panel did not follow the hand: \(start) -> \(view.frame)")
        #expect(f.state.chiefPanel.floatingFrame != savedBefore, "\(style): the new place was not kept")
        let left = view.frame

        f.controller.hideChiefPanel()
        f.frame()
        #expect(f.controller.toggleChiefPanel())
        f.controller.focusStagePane(toward: nil) // the keys go back to the stage: a collapsing style rests again
        f.frame()
        #expect(view.frame == left, "\(style): the panel did not come back where it was left: \(left) -> \(view.frame)")

        // A second drag from the new place, toward the window's far corner: it stays inside the window.
        try Self.drag(view, by: CGVector(dx: 900, dy: 900), in: f)
        let host = try #require(view.superview).bounds
        #expect(host.contains(view.frame), "\(style): the panel left the window: \(view.frame) in \(host)")
        #expect(view.frame.minX > left.minX, "\(style): the second drag did not move it")
    }

    /// The compose bar, the pill and the bubble rest small while the keys are elsewhere and grow into the whole chat
    /// once the Chief has them; the others show the whole chat.
    @Test(arguments: ChiefPanelStyle.allCases)
    func theCollapsingStylesGrowIntoTheChatWithTheKeys(_ style: ChiefPanelStyle) async throws {
        let (f, view, _) = try await Self.openPanel(style)
        defer { f.close() }
        let collapses = [ChiefPanelStyle.composeBar, .pill, .bubble, .seeThroughBar].contains(style)
        let resting = view.frame
        #expect((resting.height < 100) == collapses, "\(style): resting height \(resting.height)")
        f.controller.frameFocusChiefPanel()
        f.frame()
        #expect(f.controller.frameChiefPanelHasKeys)
        #expect(view.frame.height > 300, "\(style): with the keys the Chief did not grow into the chat: \(view.frame)")
        f.controller.focusStagePane(toward: nil)
        f.frame()
        #expect(view.frame == resting, "\(style): without the keys it did not rest again: \(view.frame)")
    }

    /// The see-through styles (user 2026-11-07, "iMessage style: very transparent and minimal"): no panel glass behind
    /// the chat, so the workspace shows through between the bubbles; what stays readable over any background is the
    /// Chief's own bubbles with a halo around its text, and a glass plate under the message box. The others keep
    /// the panel glass.
    @Test(arguments: ChiefPanelStyle.allCases)
    func theSeeThroughStylesDropThePanelGlassButKeepTheTextReadable(_ style: ChiefPanelStyle) async throws {
        let (f, view, chief) = try await Self.openPanel(style)
        defer { f.close() }
        f.controller.frameFocusChiefPanel()
        f.frame()
        let clear = style == .seeThrough || style == .seeThroughBar
        #expect(style.isSeeThrough == clear)
        #expect(view.showsPanelGlass == !clear, "\(style): panel glass \(view.showsPanelGlass)")
        #expect((chief.shadow != nil) == clear, "\(style): no halo keeps the Chief's text readable over the workspace")
        let plate = view.composerPlate
        #expect((plate != nil) == clear, "\(style): the message box has no plate")
        if let plate { #expect(plate.minY >= view.bounds.height - 80 && plate.width >= view.bounds.width - 2, "\(style): plate \(plate)") }
    }

    /// Both message-bar styles rest as a bar along the bottom of their place (the see-through one rested as a 44 pt
    /// square with the message box cut off in the first capture); the pill and the bubble rest small at the right.
    @Test(arguments: [ChiefPanelStyle.composeBar, .seeThroughBar])
    func theMessageBarStylesRestAsAFullBar(_ style: ChiefPanelStyle) async throws {
        let (f, view, _) = try await Self.openPanel(style)
        defer { f.close() }
        #expect(view.frame.width >= 200 && view.frame.height <= 60, "\(style) rests as \(view.frame)")
    }

    /// A floating panel is a card inside the window, so its corners are concentric with the window's, like the main
    /// pane's: the window's radius less the gutter (10 pt in a 16 pt window across 6 pt). A resting bar is no rounder (the pill and the bubble rest round).
    @Test(arguments: ChiefPanelStyle.allCases)
    func theFloatingPanelIsConcentricWithTheWindow(_ style: ChiefPanelStyle) async throws {
        let (f, view, _) = try await Self.openPanel(style)
        defer { f.close() }
        let card = Metrics.windowConcentricCornerRadius(windowCornerRadius: Metrics.standardWindowCornerRadius,
                                                        edgeInset: max(Metrics.mainPaneGutter, PaneTabRowRim.height), setting: nil)
        if style != .pill && style != .bubble { #expect(view.shapeCornerRadius <= card, "\(style) rests with radius \(view.shapeCornerRadius), the card's is \(card)") }
        f.controller.frameFocusChiefPanel()
        f.frame()
        #expect(view.shapeCornerRadius == card, "\(style) floats with radius \(view.shapeCornerRadius), not the window's concentric \(card)")
    }

    /// The chat itself leaves its background clear in the see-through styles (the Home chat paints its theme's
    /// background, which hid the workspace behind it in the first see-through capture), and paints it again in the
    /// other styles and once it leaves the panel.
    @Test func theChatLeavesItsBackgroundClearOnlyWhileSeeThrough() async throws {
        let chat = ClearableChat()
        let f = try await ChiefPanelWindowTests.fixture(chat)
        defer { f.close() }
        f.controller.armChiefPanel()
        f.services.windows.show(workspaceID: "k1", in: f.state)
        f.frame()
        let view = try #require(f.controller.chiefPanelView)
        try #require(f.controller.frameChiefPanelShown, "the link opened no Chief")
        for style in ChiefPanelStyle.allCases {
            view.style = style
            f.frame()
            #expect(chat.chiefShowsThrough == style.isSeeThrough, "\(style): the chat's background clear \(chat.chiefShowsThrough)")
        }
        view.style = .seeThrough
        f.frame()
        view.release()
        #expect(!chat.chiefShowsThrough, "the chat stayed clear after it left the panel")
    }

    final class ClearableChat: NSView, ChiefPanelContent {
        var chiefIsAnswering = false
        var chiefShowsThrough = false
        init() { super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400)) }
        @available(*, unavailable) required init?(coder: NSCoder) { nil }
    }

    /// "Sees your screen" (user 2026-11-07): an eye in the panel says the Chief gets a look at the screen when it
    /// opens, on by default; a click on it turns it off (and on), through the setting.
    @Test func theEyeShowsWhetherTheChiefSeesTheScreenAndTogglesIt() async throws {
        let (f, view, _) = try await Self.openPanel(.card)
        defer { f.close() }
        var toggles = 0
        view.actions.toggleSeesScreen = { toggles += 1 }
        let eye = try #require(Self.find("window.chiefPanel.seesScreen", in: view) as? NSButton, "no eye in the panel")
        #expect(!eye.isHidden && view.seesScreen, "the eye is hidden or off by default")
        eye.performClick(nil)
        #expect(toggles == 1)
        view.seesScreen = false
        #expect(eye.toolTip != nil && eye.image?.accessibilityDescription != nil)
    }

    static func find(_ id: String, in view: NSView) -> NSView? {
        if view.accessibilityIdentifier() == id { return view }
        for child in view.subviews { if let found = find(id, in: child) { return found } }
        return nil
    }

    @MainActor @Observable final class StyleBox { var style = ChiefPanelStyle.panel }

    /// The panel follows its style source (the setting) live, and a later change of the source switches it again.
    @Test func thePanelFollowsTheStyleSettingLive() async throws {
        let (f, view, _) = try await Self.openPanel(.panel)
        defer { f.close() }
        let box = StyleBox()
        view.follow { box.style }
        box.style = .pill
        for _ in 0..<20 where view.style != .pill { await Task.yield(); f.frame() }
        #expect(view.style == .pill, "the panel did not follow the setting")
        box.style = .card
        for _ in 0..<20 where view.style != .card { await Task.yield(); f.frame() }
        #expect(view.style == .card)
    }

    /// Records registrations instead of calling Carbon.
    final class Recorder: GlobalHotKeyRegistrar {
        var onPress: ((UInt32) -> Void)?
        var registered: [UInt32: CarbonHotKey] = [:]
        func register(_ hotKey: CarbonHotKey, number: UInt32) -> Bool { registered[number] = hotKey; return true }
        func unregister(number: UInt32) { registered[number] = nil }
    }

    static let anyAppAction: ActionID = "home.showHideChiefFromAnyApp"
    static let anyAppKey = Shortcut(Shortcut.spaceKey, modifiers: [.option, .shift])

    /// Show/Hide Chief from Any App: a system-wide key, Option-Shift-Space by default, rebindable in Settings >
    /// Keyboard Shortcuts, that brings cmux forward and opens the floating Chief.
    @Test func theGlobalKeyOpensTheFloatingChiefFromAnyApp() async throws {
        let (chief, _) = ChiefPanelWindowTests.chiefView()
        let f = try await ChiefPanelWindowTests.fixture(chief)
        defer { f.close() }
        AppActions.bind(f.services)
        let registry = f.services.registry
        let descriptor = try #require(registry.descriptor(for: Self.anyAppAction), "no Show/Hide Chief from Any App")
        #expect(descriptor.isGlobalHotKey && descriptor.defaultShortcut == Self.anyAppKey)
        #expect(descriptor.surfaces.contains(.keyboard), "no row in Settings > Keyboard Shortcuts")
        #expect(descriptor.isPersonOnly, "an agent could pull cmux in front of the person's app")
        #expect(SystemReservedShortcuts.shared.table[Self.anyAppKey] == nil)
        #expect(!registry.shortcutConflictGroups().contains { $0.shortcut == Self.anyAppKey }, "another default takes Option-Shift-Space")

        f.services.windows.show(workspaceID: "k1", in: f.state, from: .thisWindow)
        f.frame()
        let recorder = Recorder()
        let service = GlobalHotKeyService(registry: registry, registrar: recorder, layout: { .ansi },
                                          showHideEnabled: { false }, startAgentEnabled: { false })
        service.start()
        defer { service.stop() }
        let hotKey = try #require(CarbonHotKey(Self.anyAppKey, layout: .ansi))
        let number = try #require(recorder.registered.first(where: { $0.value == hotKey })?.key, "Option-Shift-Space is not registered")
        recorder.onPress?(number)
        f.frame()
        #expect(f.controller.frameChiefPanelShown, "the global key did not open the floating Chief")
        #expect(f.controller.frameChiefPanelHasKeys, "the opened Chief did not take the keys")
    }
}
