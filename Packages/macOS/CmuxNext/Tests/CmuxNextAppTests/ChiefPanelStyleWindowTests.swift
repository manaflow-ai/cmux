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

    /// Presses the panel's grip and drags it by `delta` (screen points, y up), as a hand does: floating, the Chief
    /// is a window of its own (``ChiefLauncherPanel``), and the window moves.
    static func drag(_ view: ChiefPanelView, by delta: CGVector, in f: Fixture) throws {
        try ChiefLauncherWindowTests.drag(at: NSPoint(x: view.gripRect.midX, y: view.gripRect.midY), in: view, by: delta)
        f.frame()
    }

    /// Every style drags by its grip, lands where it was let go (past the cmux window's edge too: it is a window of
    /// its own), and comes back there after a hide and a reopen.
    @Test(arguments: ChiefPanelStyle.allCases)
    func everyStyleDragsAndRemembersWhereItWasLeft(_ style: ChiefPanelStyle) async throws {
        let (f, view, _) = try await Self.openPanel(style)
        defer { f.close() }
        let launcher = try #require(view.launcher)
        try #require(view.window === launcher, "\(style): the floating Chief is not in its own window")
        let start = launcher.frame
        try Self.drag(view, by: CGVector(dx: -420, dy: -20), in: f)
        #expect(abs(launcher.frame.minX - (start.minX - 420)) <= 1 && abs(launcher.frame.minY - (start.minY - 20)) <= 1,
                "\(style): the window did not follow the hand: \(start) -> \(launcher.frame)")
        let screen = try #require(launcher.screen)
        #expect(launcher.frames.frame(onDisplay: FloatingChatFrames.display(screen)) == launcher.frame, "\(style): the new place was not kept")
        // Where it was left, kept on the screen when it comes back (a small screen pushes a drag past its edge).
        let left = ChiefLauncherPanel.placement(saved: launcher.frame, in: screen.visibleFrame)

        f.controller.hideChiefPanel()
        f.frame()
        #expect(!launcher.isVisible)
        #expect(f.controller.toggleChiefPanel())
        f.frame()
        #expect(launcher.frame == left, "\(style): the window did not come back where it was left: \(left) -> \(launcher.frame)")

        try Self.drag(view, by: CGVector(dx: 900, dy: 40), in: f)
        #expect(abs(launcher.frame.minX - (left.minX + 900)) <= 1, "\(style): the second drag did not move it its whole way: \(launcher.frame)")
    }

    /// In its own window every style shows the whole chat, with or without the keys: the window shows only while in
    /// use (a click outside hides it), so no style rests small there.
    @Test(arguments: ChiefPanelStyle.allCases)
    func everyStyleShowsTheWholeChatInItsWindow(_ style: ChiefPanelStyle) async throws {
        let (f, view, _) = try await Self.openPanel(style)
        defer { f.close() }
        let launcher = try #require(view.launcher)
        #expect(view.frame == launcher.contentView?.bounds, "\(style): the Chief does not fill its window: \(view.frame)")
        #expect(view.frame.height > 300, "\(style): without the keys: \(view.frame)")
        f.controller.frameFocusChiefPanel()
        f.frame()
        #expect(f.controller.frameChiefPanelHasKeys)
        #expect(view.frame == launcher.contentView?.bounds, "\(style): with the keys: \(view.frame)")
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
        #expect(chief.shadow == nil, "\(style): a halo over the whole chat blurs every bubble; only the header gets a plate")
        let plate = view.composerPlate
        #expect((plate != nil) == clear, "\(style): the message box has no plate")
        if let plate { #expect(plate.minY >= view.bounds.height - 80 && plate.width >= view.bounds.width - 2, "\(style): plate \(plate)") }
    }

    /// Floating, the Chief is a window of its own, so it has a window's corners; docked, it is square at its edge.
    @Test(arguments: ChiefPanelStyle.allCases)
    func theFloatingChiefHasAWindowsCorners(_ style: ChiefPanelStyle) async throws {
        let (f, view, _) = try await Self.openPanel(style)
        defer { f.close() }
        #expect(view.shapeCornerRadius == Metrics.standardWindowCornerRadius, "\(style) floats with radius \(view.shapeCornerRadius)")
        f.controller.frameFocusChiefPanel()
        f.frame()
        #expect(view.shapeCornerRadius == Metrics.standardWindowCornerRadius, "\(style) with the keys: radius \(view.shapeCornerRadius)")
        f.controller.dockChiefPanel(at: .left)
        f.frame()
        #expect(view.shapeCornerRadius == 0, "\(style) docked with radius \(view.shapeCornerRadius)")
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

    /// The see-through styles keep the bar and the chat's header readable over busy text (user 2026-11-08: "tight
    /// halo behind the header only, not the whole chat"): a glass plate from the panel's top down to the header's
    /// bottom, and no lower (a little fade aside), so the bubbles under it still show the workspace.
    @Test func theSeeThroughStylesKeepAPlateBehindTheHeaderOnly() async throws {
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
            f.controller.frameFocusChiefPanel()  // the keys in the panel: a collapsing style grows to show its header
            f.frame()
            #expect(f.controller.frameChiefPanelHasKeys, "\(style): the panel did not take the keys")
            guard style.isSeeThrough else { #expect(view.headerPlate == nil, "\(style) draws a header plate"); continue }
            let plate = try #require(view.headerPlate, "\(style): the header has no plate over busy text")
            let bottom = view.convert(chat.bounds, from: chat).minY + chat.chiefHeaderHeight  // under the bar or strip
            #expect(plate.minY <= 0 && plate.width >= view.bounds.width - 2, "\(style): plate \(plate)")
            #expect(plate.maxY >= bottom && plate.maxY <= bottom + ChiefPanelView.headerPlateFade,
                    "\(style): the plate ends at \(plate.maxY), the header at \(bottom)")
        }
    }

    final class ClearableChat: NSView, ChiefPanelContent {
        var chiefIsAnswering = false
        var chiefShowsThrough = false
        var chiefHeaderHeight: CGFloat = 72
        init() {
            super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 400))
            addSubview(NSTextView(frame: NSRect(x: 8, y: 8, width: 220, height: 40)))  // a message box to take the keys
        }
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
        #expect(eye.themedToolTip != nil && eye.image?.accessibilityDescription != nil)
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
