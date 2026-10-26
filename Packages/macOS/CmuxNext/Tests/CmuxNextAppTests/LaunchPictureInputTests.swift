import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFocus
import CmuxNextFocusUI
import CmuxNextLaunch
import Foundation
import Testing

/// Input while a window shows its launch picture (p08-startup-061). A key changes only the model in its turn: a
/// chord runs its registry action, and typing for a terminal that is still a picture waits in that terminal's
/// stand-in buffer, which raises the pane's slice to the next frame and reaches the terminal exactly once, in order,
/// when it is live. A click on a region that is not live is held and sent again at the same point when the region is
/// live (within 2 s), dropped when its model changed; a resize or a full-screen toggle removes the picture at once.
@MainActor @Suite(.serialized)
struct LaunchPictureInputTests {
    // MARK: Keys, through the router

    private struct Harness {
        let services: AppServices
        let controller: WindowController
        let shell: NSWindow
        var router: KeyRouter { services.keyRouter }
        func close() { for controller in services.windows.controllers { controller.window?.close() } }
    }

    private static func harness() throws -> Harness {
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        AppActions.bind(services)
        services.windows.ordersWindowsIn = false
        let controller = try #require(services.windows.openWindow(workspaces: ["picture-workspace"]))
        let shell = try #require(controller.window)
        controller.focus.send(.topology(FocusTopology(workspace: "picture-workspace", panes: [
            .init(id: "picture-pane", tabs: [.init(id: "picture-tab", kind: .terminal)], selected: "picture-tab"),
        ])))
        controller.focus.send(.focusPane("picture-pane", source: .keyboard))
        try #require(controller.focus.state.resolved == .terminal(pane: "picture-pane", tab: "picture-tab"))
        return Harness(services: services, controller: controller, shell: shell)
    }

    private static var timestamp: TimeInterval = 12_000

    private static func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = [],
                            window: Int = 0) throws -> NSEvent {
        timestamp += 0.01
        return try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: timestamp,
                                             windowNumber: window, context: nil, characters: characters,
                                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
    }

    private static func dispatch(_ event: NSEvent, in harness: Harness) -> Bool {
        harness.router.dispatchingSynthetic(event) { harness.router.interceptKeyDown(event, in: harness.shell) }
    }

    /// Typing while the focused terminal is a picture waits for it: the router takes each key, raises the pane's
    /// slice once (not per key, and only that pane), and turns its mode on only while the picture shows.
    @Test func typingForATerminalStillAPictureWaitsAndRaisesOnlyItsPane() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let keys = harness.router.launchPictureKeys
        let target = LaunchPictureKeys.Target(window: harness.controller.state.id, pane: "picture-pane", tab: "picture-tab")
        var raised: [String] = []
        #expect(!harness.router.modes.contains(.launchPicture))
        keys.begin(window: target.window) { raised.append($0) }
        #expect(harness.router.modes.contains(.launchPicture), "the picture phase did not turn the router's mode on")

        for (letter, code) in [("l", UInt16(37)), ("s", 1), ("\r", 36)] {
            #expect(Self.dispatch(try Self.key(letter, keyCode: code, window: harness.shell.windowNumber), in: harness),
                    "the key for a terminal still a picture went on to a view that cannot take it")
        }
        #expect(keys.isHolding(target))
        #expect(raised == ["picture-pane"], "raised \(raised): the slice is raised once, for the focused pane only")
    }

    /// A Command chord is a registry action: it runs in its turn, never waits behind the picture.
    @Test func aCommandChordIsNeverHeldForThePicture() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        let keys = harness.router.launchPictureKeys
        keys.begin(window: harness.controller.state.id) { _ in }
        let chord = try Self.key("k", keyCode: 40, modifiers: .command, window: harness.shell.windowNumber)
        #expect(!harness.router.holdsForLaunchPicture(chord, in: harness.shell))
        #expect(!keys.isHolding(.init(window: harness.controller.state.id, pane: "picture-pane", tab: "picture-tab")))
    }

    /// Outside the picture phase the router never asks the stand-in buffer (normal mode stays normal).
    @Test func noPictureNoHold() throws {
        let harness = try Self.harness()
        defer { harness.close() }
        #expect(harness.router.modes.isNormal)
        #expect(!harness.router.holdsForLaunchPicture(try Self.key("a", keyCode: 0, window: harness.shell.windowNumber), in: harness.shell))
    }

    // MARK: Keys, the stand-in buffer

    private final class FakeTerminals {
        var live: Set<LaunchPictureKeys.Target> = []
        var received: [LaunchPictureKeys.Target: [String]] = [:]

        func deliver(_ target: LaunchPictureKeys.Target, _ events: [NSEvent]) -> Bool {
            guard live.contains(target) else { return false }
            received[target, default: []] += events.map { $0.characters ?? "" }
            return true
        }
    }

    private static let a = LaunchPictureKeys.Target(window: "w", pane: "pane-a", tab: "tab-a")
    private static let b = LaunchPictureKeys.Target(window: "w", pane: "pane-b", tab: "tab-b")

    /// Keys typed for a terminal reach it exactly once, in order, when it goes live; a focus move between them
    /// (a chord ran its action) sends the later keys to the new terminal, never the earlier ones.
    @Test func eachKeyReachesTheTerminalItWasTypedForExactlyOnce() throws {
        let terminals = FakeTerminals()
        let keys = LaunchPictureKeys { terminals.deliver($0, $1) }
        keys.begin(window: "w") { _ in }
        for letter in ["e", "c", "h", "o"] { keys.hold(try Self.key(letter, keyCode: 0), for: Self.a) }
        for letter in ["x", "y"] { keys.hold(try Self.key(letter, keyCode: 0), for: Self.b) }
        keys.retry()
        #expect(terminals.received.isEmpty, "a key reached a terminal that is not live")

        terminals.live.insert(Self.b)
        keys.retry()
        terminals.live.insert(Self.a)
        keys.end(window: "w")
        keys.retry()
        #expect(terminals.received[Self.a] == ["e", "c", "h", "o"])
        #expect(terminals.received[Self.b] == ["x", "y"])
        #expect(!keys.isActive && keys.dropped == 0)
    }

    /// A key for a terminal that is live already goes at once, behind the keys typed for it before.
    @Test func aKeyForALiveTerminalGoesAtOnceBehindTheEarlierOnes() throws {
        let terminals = FakeTerminals()
        let keys = LaunchPictureKeys { terminals.deliver($0, $1) }
        keys.begin(window: "w") { _ in }
        keys.hold(try Self.key("1", keyCode: 18), for: Self.a)
        terminals.live.insert(Self.a)
        keys.hold(try Self.key("2", keyCode: 19), for: Self.a)
        #expect(terminals.received[Self.a] == ["1", "2"])
        #expect(!keys.isHolding(Self.a))
    }

    /// The test phase's burst, at the model: in 10 launches, a burst typed 10 ms after the first frame loses no key,
    /// whenever in the picture phase the terminal goes live.
    @Test func aBurstTenMillisecondsAfterTheFirstFrameLosesNoKeyInTenLaunches() throws {
        for launch in 0 ..< 10 {
            let start = ContinuousClock.now
            var elapsed = Duration.milliseconds(10)
            let terminals = FakeTerminals()
            let keys = LaunchPictureKeys(now: { start + elapsed }) { terminals.deliver($0, $1) }
            keys.begin(window: "w") { _ in }
            let burst = (0 ..< 20).map { "k\(launch)-\($0)" }
            for (index, text) in burst.enumerated() {
                keys.hold(try Self.key(text, keyCode: 0), for: Self.a)
                elapsed += .milliseconds(8)
                // The terminal's first frame lands somewhere in the burst (later each launch).
                if index == launch * 2 { terminals.live.insert(Self.a) }
            }
            keys.end(window: "w")
            #expect(terminals.received[Self.a] == burst, "launch \(launch) lost or reordered keys")
            #expect(keys.dropped == 0)
        }
    }

    /// A terminal that never goes live does not keep its keys (or the router's slow path) forever.
    @Test func keysForATerminalThatNeverGoesLiveAreDroppedAfterTheLimit() throws {
        let start = ContinuousClock.now
        var elapsed = Duration.zero
        var active: [Bool] = []
        let keys = LaunchPictureKeys(limit: .seconds(5), now: { start + elapsed }) { _, _ in false }
        keys.onActiveChange = { active.append($0) }
        keys.begin(window: "w") { _ in }
        keys.hold(try Self.key("z", keyCode: 6), for: Self.a)
        keys.end(window: "w")
        #expect(keys.isActive, "the key was dropped before its limit")
        elapsed = .seconds(6)
        keys.retry()
        #expect(!keys.isActive && keys.dropped == 1)
        #expect(active == [true, false])
    }

    // MARK: Clicks

    private final class Recorder {
        var raised: [String] = []
        var sent: [NSEvent.EventType] = []
        var left: [LaunchPictureView.Leave] = []
        var stamps: [String: String] = ["tab-1": "tab-1", "sidebar": "rows-1"]
        var elapsed = Duration.zero
        let start = ContinuousClock.now
    }

    private static func picture(_ recorder: Recorder) throws -> LaunchPictureView {
        let context = try #require(CGContext(data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        let meta = WindowPictureMeta(window: "w", profile: "default", frame: CGRect(x: 0, y: 0, width: 400, height: 200), screen: nil,
                                     scale: 1, appearance: "NSAppearanceNameDarkAqua", theme: "t", sidebarWidth: 100, build: "1 (1)",
                                     layout: .init(workspaces: ["ws"], shown: "ws", screens: []),
                                     regions: [.init(kind: .sidebar, id: "sidebar", frame: CGRect(x: 0, y: 0, width: 100, height: 200)),
                                               .init(kind: .pane, id: "tab-1", frame: CGRect(x: 100, y: 40, width: 300, height: 160))])
        let host = LaunchPictureView.Host(modelStamp: { recorder.stamps[$0.id] }, raise: { recorder.raised.append($0.id) },
                                          resend: { recorder.sent.append($0.type) }, didLeave: { recorder.left.append($0) })
        return LaunchPictureView(picture: image, meta: meta, scale: 1, host: host, now: { recorder.start + recorder.elapsed })
    }

    private static func mouse(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }

    /// In the pane (x 100...400, from the top 40...200: AppKit's y 0...160).
    private static let inPane = CGPoint(x: 200, y: 80)
    /// Above every region (the tab strip's band, AppKit's y 160...200).
    private static let inChrome = CGPoint(x: 200, y: 190)

    /// A click on a pane still a picture waits for it and raises its slice; when the pane is live with the same
    /// tab, the mouse-down and mouse-up go again exactly once, in order.
    @Test func aClickOnARegionNotLiveIsSentAgainOnceWhenItGoesLive() throws {
        let recorder = Recorder()
        let view = try Self.picture(recorder)
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: Self.inPane))
        view.mouseUp(with: try Self.mouse(.leftMouseUp, at: Self.inPane))
        #expect(recorder.raised == ["tab-1"])
        #expect(recorder.sent.isEmpty, "a click went to a view that is not built")
        recorder.elapsed = .milliseconds(400)
        view.regionDidGoLive("tab-1")
        view.regionDidGoLive("tab-1")
        #expect(recorder.sent == [.leftMouseDown, .leftMouseUp])
    }

    /// The region went live between the press and the release: the release follows the press at once.
    @Test func aReleaseAfterTheRegionWentLiveFollowsItsPress() throws {
        let recorder = Recorder()
        let view = try Self.picture(recorder)
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: Self.inPane))
        view.regionDidGoLive("tab-1")
        #expect(recorder.sent == [.leftMouseDown])
        view.mouseUp(with: try Self.mouse(.leftMouseUp, at: Self.inPane))
        #expect(recorder.sent == [.leftMouseDown, .leftMouseUp])
    }

    /// The pane shows another tab now: the click meant the old one and is dropped.
    @Test func aClickWhoseRegionsModelChangedIsDropped() throws {
        let recorder = Recorder()
        let view = try Self.picture(recorder)
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: Self.inPane))
        view.mouseUp(with: try Self.mouse(.leftMouseUp, at: Self.inPane))
        recorder.stamps["tab-1"] = "tab-2"
        view.regionDidGoLive("tab-1")
        #expect(recorder.sent.isEmpty)
    }

    /// A region live after the 2 s hold: the click is dropped.
    @Test func aClickOlderThanTheHoldIsDropped() throws {
        let recorder = Recorder()
        let view = try Self.picture(recorder)
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: Self.inPane))
        recorder.elapsed = .milliseconds(2100)
        view.regionDidGoLive("tab-1")
        #expect(recorder.sent.isEmpty)
    }

    /// A click outside every region goes to the live window when the picture leaves.
    @Test func aClickOnTheChromeIsSentWhenThePictureLeaves() throws {
        let recorder = Recorder()
        let view = try Self.picture(recorder)
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: Self.inChrome))
        view.mouseUp(with: try Self.mouse(.leftMouseUp, at: Self.inChrome))
        #expect(recorder.raised.isEmpty)
        view.finish()
        #expect(recorder.left == [.finished] && view.hasLeft)
        #expect(recorder.sent == [.leftMouseDown, .leftMouseUp])
    }

    /// A live region lets clicks through to the live view; a region still a picture takes them.
    @Test func aLiveRegionLetsClicksThrough() throws {
        let recorder = Recorder()
        let view = try Self.picture(recorder)
        let container = NSView(frame: view.frame)
        container.addSubview(view)
        #expect(view.hitTest(Self.inPane) === view)
        view.regionDidGoLive("tab-1")
        #expect(view.hitTest(Self.inPane) == nil)
        #expect(view.hitTest(CGPoint(x: 50, y: 50)) === view, "the sidebar is still a picture")
    }

    /// A resize (a full-screen toggle resizes too) removes the picture at once, with the clicks it held: their
    /// points no longer mean the same place.
    @Test func aResizeRemovesThePictureAtOnceAndDropsItsClicks() throws {
        let recorder = Recorder()
        let view = try Self.picture(recorder)
        let container = NSView(frame: view.frame)
        container.addSubview(view)
        view.mouseDown(with: try Self.mouse(.leftMouseDown, at: Self.inPane))
        view.setFrameSize(CGSize(width: 1440, height: 900))
        #expect(view.hasLeft && view.superview == nil)
        #expect(recorder.left == [.geometryChanged])
        view.regionDidGoLive("tab-1")
        view.finish()
        #expect(recorder.sent.isEmpty && recorder.left == [.geometryChanged])
    }
}
