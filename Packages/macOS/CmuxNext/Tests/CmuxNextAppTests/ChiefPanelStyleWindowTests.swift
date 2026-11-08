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
        window.sendEvent(mouse(.leftMouseDown, at: grip, in: window))
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
        try Self.drag(view, by: CGVector(dx: -420, dy: -160), in: f)
        #expect(abs(view.frame.minX - (start.minX - 420)) <= 1 && abs(view.frame.minY - (start.minY - 160)) <= 1,
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
        let collapses = [ChiefPanelStyle.composeBar, .pill, .bubble].contains(style)
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

    @Observable final class StyleBox { var style = ChiefPanelStyle.panel }

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
