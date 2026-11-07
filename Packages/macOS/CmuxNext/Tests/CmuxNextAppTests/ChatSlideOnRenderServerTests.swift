import AppKit
import CmuxNextTestSupport
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// A pane sliding in beside a chat moves on the render server, so a busy main thread never stops it (Leo 2026-11-07, on
/// Reopen Closed of a right-split agent pane: "it should just reopen on the right straight up and just play that
/// rightmost opening animation"; under STRESS the main-thread spring stood still mid-way, three motions). The change's
/// own pass places every frame at rest, and additive springs on the hosts' and the divider's layers carry what shows
/// from where it was, all from one begin time. A test driver that steps the springs itself keeps them on the main thread
/// (`ChatPanelSlideInTests`).
@MainActor
@Suite(.closesItsWindows)
struct ChatSlideOnRenderServerTests {
    final class Panes: LayoutPaneContentProvider {
        let holding: Set<PaneID>
        init(holding: Set<PaneID>) { self.holding = holding }
        func makeContentView(for pane: PaneID) -> NSView { NSView() }
        func holdsContentInMotion(for pane: PaneID) -> Bool { holding.contains(pane) }
    }

    final class Screen {
        let provider: Panes
        let model: LayoutModel
        let root: LayoutRootView
        let window: NSWindow

        init(_ tree: SplitNode, holding: Set<PaneID>) {
            provider = Panes(holding: holding)
            model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s",
                                focusedPane: tree.panes.first)
            root = LayoutRootView(model: model, contentProvider: provider)
            root.context.reduceMotionOverride = false
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
                              backing: .buffered, defer: true)
            window.contentView = root
            root.layoutSubtreeIfNeeded()
        }

        var screen: ScreenContentView? { root.screenViews["s"] }

        func show(_ tree: SplitNode) {
            model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
            root.syncWithModel()
        }

        /// The additive springs `ServerSpring` put on `view`'s layer, by key path.
        func springs(on view: NSView?) -> [String: CASpringAnimation] {
            guard let layer = view?.layer else { return [:] }
            var found: [String: CASpringAnimation] = [:]
            for key in layer.animationKeys() ?? [] where key.hasPrefix(ServerSpring.key) {
                if let spring = layer.animation(forKey: key) as? CASpringAnimation, spring.isAdditive, let path = spring.keyPath {
                    found[path] = spring
                }
            }
            return found
        }
    }

    static let opened: SplitNode = .split("r", axis: .horizontal, ratio: 0.5, a: .leaf("chat"), b: .leaf("panel"))

    @Test func aPanelSlidingInBesideAChatMovesOnTheRenderServer() throws {
        let screen = Screen(.leaf("chat"), holding: ["chat"])
        defer { screen.window.closeAfterTest() }
        screen.show(Self.opened)
        let view = try #require(screen.screen)
        // Every frame is at rest in the change's own pass: no main-thread frame is left to step.
        for (pane, frame) in view.paneFrames {
            #expect(frame.rect == frame.targetRect, "\(pane) still springs on the main thread: \(frame.rect) to \(frame.targetRect)")
        }
        #expect(!view.hasMotion)
        let panelHost = try #require(view.context.hosts["panel"]), chatHost = try #require(view.context.hosts["chat"])
        // The panel slides in from the right at its final width: a position spring only, starting right of its place.
        let slide = try #require(screen.springs(on: panelHost)["position"], "the panel has no render-server slide")
        #expect(((slide.fromValue as? NSValue)?.pointValue.x ?? 0) > 1, "the panel starts right of its place")
        #expect(screen.springs(on: panelHost)["bounds.size"] == nil, "the panel never resizes")
        // The chat shrinks from the whole width on the same spring and begin time.
        let shrink = try #require(screen.springs(on: chatHost)["bounds.size"], "the chat has no render-server shrink")
        #expect(((shrink.fromValue as? NSValue)?.sizeValue.width ?? 0) > 1, "the chat starts wider than it rests")
        #expect(shrink.beginTime == slide.beginTime, "the chat and the panel begin together")
        // The divider rides the same edge.
        let divider = try #require(view.dividerViews.values.first)
        let edge = try #require(screen.springs(on: divider)["position"], "the divider does not move with them")
        #expect(edge.beginTime == slide.beginTime)
        #expect(((edge.fromValue as? NSValue)?.pointValue.x ?? 0) > 1, "the divider starts at the chat's old edge")
    }

    /// A change that lands while the slide runs (the panel closed again at once) takes the render-server springs off and
    /// starts from what shows, instead of adding its motion on top of their offset (review F1 at 3650d375).
    @Test func aChangeMidSlideTakesTheRenderServerSpringsBack() throws {
        let screen = Screen(.leaf("chat"), holding: ["chat"])
        defer { screen.window.closeAfterTest() }
        screen.show(Self.opened)
        let view = try #require(screen.screen)
        let chatHost = try #require(view.context.hosts["chat"])
        #expect(!screen.springs(on: chatHost).isEmpty)
        screen.show(.leaf("chat"))
        #expect(screen.springs(on: chatHost).isEmpty, "the slide's springs still run under the close")
        #expect(screen.springs(on: chatHost.chrome).isEmpty, "the ring's springs still run under the close")
        for divider in view.dividerViews.values { #expect(screen.springs(on: divider).isEmpty) }
    }

    /// The daemon's echo of the split with its own sizes lands mid-slide: the slide stays on the render server (its new
    /// springs add to the running ones) instead of going back to main-thread frames, which stand still under load.
    @Test func anEchoWithOtherSizesMidSlideStaysOnTheRenderServer() throws {
        let screen = Screen(.leaf("chat"), holding: ["chat"])
        defer { screen.window.closeAfterTest() }
        screen.show(Self.opened)
        let view = try #require(screen.screen)
        let chatHost = try #require(view.context.hosts["chat"])
        let before = chatHost.layer?.animationKeys()?.filter { $0.hasPrefix(ServerSpring.key) }.count ?? 0
        screen.show(.split("r", axis: .horizontal, ratio: 0.55, a: .leaf("chat"), b: .leaf("panel")))
        #expect(!view.hasMotion, "the echo put the slide back on main-thread frames")
        for (pane, frame) in view.paneFrames { #expect(frame.rect == frame.targetRect, "\(pane) springs on the main thread") }
        let after = chatHost.layer?.animationKeys()?.filter { $0.hasPrefix(ServerSpring.key) }.count ?? 0
        #expect(after > before, "the echo's move is not on the render server: \(before) springs, then \(after)")
    }

    /// Reduce Motion turned on or the window out of sight mid-slide (`landMotion`) lands it: no spring is left to run
    /// or to play again when the window shows (review F1 at a5b95568).
    @Test func landingTheLayoutStopsARenderServerSlide() throws {
        let screen = Screen(.leaf("chat"), holding: ["chat"])
        defer { screen.window.closeAfterTest() }
        screen.show(Self.opened)
        let view = try #require(screen.screen)
        #expect(view.hasServerMotion)
        screen.root.landMotion()
        #expect(!view.hasServerMotion)
        for host in view.displayedHosts {
            #expect(screen.springs(on: host).isEmpty && screen.springs(on: host.chrome).isEmpty)
        }
        for divider in view.dividerViews.values { #expect(screen.springs(on: divider).isEmpty) }
    }

    /// Cmd-D in a pane that lays out live (a terminal) keeps the main-thread spring, which lays it out on every frame.
    @Test func aSplitOfAPaneThatDoesNotHoldItsContentStaysOnTheMainThread() throws {
        let screen = Screen(.leaf("chat"), holding: [])
        defer { screen.window.closeAfterTest() }
        screen.show(Self.opened)
        let view = try #require(screen.screen)
        #expect(view.hasMotion, "a sliver split still springs frame by frame")
        #expect(screen.springs(on: view.context.hosts["panel"]).isEmpty)
    }
}
