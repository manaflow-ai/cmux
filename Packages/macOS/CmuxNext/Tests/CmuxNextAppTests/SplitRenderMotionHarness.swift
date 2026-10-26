import AppKit
import CmuxNextDesign
@testable import CmuxNextLayout
import QuartzCore
import Testing

/// Pane content that records what its pane's layout spring tells it and every size it is given.
final class SplitRenderContent: NSView, PaneMotionTargeting, PaneMotionSettling {
    var willRest: [CGSize] = []
    var settled = 0
    var sizes: [CGSize] = []

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        sizes.append(newSize)
    }

    func paneMotionWillRest(sizeChange: CGSize) -> PaneMotionAnchor {
        willRest.append(sizeChange)
        return .top
    }

    func paneMotionDidSettle() { settled += 1 }
}

final class SplitRenderPanes: LayoutPaneContentProvider {
    var contents: [PaneID: SplitRenderContent] = [:]

    func makeContentView(for pane: PaneID) -> NSView {
        let content = SplitRenderContent()
        content.wantsLayer = true
        contents[pane] = content
        return content
    }
}

/// A real, ordered-in window (a window on no screen does not animate) with one layout screen `s`, and the
/// render server's clock under the layout root that a test can stop and scrub.
@MainActor
final class SplitRenderWindow {
    let panes = SplitRenderPanes()
    let model: LayoutModel
    let root: LayoutRootView
    let window: NSWindow
    /// Every layout motion start (true) and end (false) the root announced.
    var motion: [Bool] = []
    private var observation: LayoutOverlaySyncObservation?
    private var landing: CheckedContinuation<Bool, Never>?

    init(renderServer: Bool, reduceMotion: Bool = false, width: CGFloat = 1200, tree: SplitNode = .leaf("a")) {
        model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))], activeScreenID: "s", focusedPane: "a")
        root = LayoutRootView(model: model, contentProvider: panes, rendersMotionOnServer: { renderServer })
        root.context.reduceMotionOverride = reduceMotion
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 800), styleMask: [.borderless],
                          backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = root
        window.orderFrontRegardless()
        root.layoutSubtreeIfNeeded()
        observation = root.observeLayoutMotion { [weak self] moving in
            guard let self else { return }
            motion.append(moving)
            if !moving { resumeLanding(true) }
        }
    }

    var screen: ScreenContentView { root.screenViews["s"]! }

    func host(_ pane: PaneID) throws -> PaneHostView { try #require(root.context.hosts[pane]) }

    func layer(_ pane: PaneID) throws -> CALayer { try #require(host(pane).layer) }

    func content(_ pane: PaneID) throws -> SplitRenderContent { try #require(panes.contents[pane]) }

    /// The daemon's tree after a key (Cmd-D, Cmd-W), applied in the key's turn.
    func apply(_ tree: SplitNode) {
        model.apply(screens: [LayoutScreen(id: "s", name: "s", layout: .splits(tree))])
        root.syncWithModel()
    }

    /// Cmd-D on `a` alone: `b` opens on its right.
    func split() { apply(.split(SplitID("d"), axis: .horizontal, ratio: 0.5, a: .leaf("a"), b: .leaf("b"))) }

    /// The frame spring's tuning for the screen's current split.
    var frameSpring: SpringParameters { Motion.panes.spring(screen.motionState.frameSpring) }

    /// Waits for the layout motion to end; false after `timeout`.
    func landed(timeout: Duration = .seconds(5)) async -> Bool {
        if motion.last == false { return true }
        return await withCheckedContinuation { continuation in
            landing = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: timeout)
                self?.resumeLanding(false)
            }
        }
    }

    private func resumeLanding(_ landed: Bool) {
        landing?.resume(returning: landed)
        landing = nil
    }

    func close() {
        observation = nil
        window.orderOut(nil)
        window.close()
    }

    // MARK: The render server's clock

    /// Stops the render server's clock under the root: springs show the time ``seek(to:)`` sets.
    func freeze() throws {
        let clock = try #require(root.layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clock.speed = 0
        clock.timeOffset = 0
        CATransaction.commit()
        CATransaction.flush()
    }

    func seek(to time: CFTimeInterval) throws {
        let clock = try #require(root.layer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clock.timeOffset = time
        CATransaction.commit()
        CATransaction.flush()
    }

    /// The frame `layer` presents (its superlayer's coordinates) `time` seconds into the frozen clock.
    func presented(_ layer: CALayer, at time: CFTimeInterval) throws -> CGRect {
        try seek(to: time)
        return try #require(layer.presentation(), "no presentation layer after a commit").frame
    }

    /// Seconds a spring from rest takes to cover `progress` of its way (cmux-motion's closed form, which the
    /// render-server spring matches within 0.25 pt, RenderSpringParityTests).
    static func time(toProgress progress: Double, _ spring: SpringParameters) -> Double {
        var time = 0.0
        while time < 5, 1 - SpringValue.solve(displacement: 1, velocity: 0, time: time, parameters: spring).displacement < progress {
            time += 0.0005
        }
        return time
    }

    /// The largest gap between two rects' edges and sizes.
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(abs(a.minX - b.minX), abs(a.minY - b.minY), abs(a.width - b.width), abs(a.height - b.height))
    }

    static func midpoint(_ a: CGRect, _ b: CGRect) -> CGRect {
        CGRect(x: (a.minX + b.minX) / 2, y: (a.minY + b.minY) / 2, width: (a.width + b.width) / 2, height: (a.height + b.height) / 2)
    }

    /// Movement animates for the panes gate (Reduce Motion pinned to `reduceMotion`).
    static func withMotion<T>(reduceMotion: Bool = false, _ body: () async throws -> T) async throws -> T {
        Motion.reduceMotionOverride = reduceMotion
        defer { Motion.reduceMotionOverride = nil }
        try #require(Motion.panes.animatesMovement != reduceMotion, "panes movement does not follow Reduce Motion on this host")
        return try await body()
    }
}
