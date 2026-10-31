import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Observation
@testable import CmuxNextLayout
import QuartzCore

/// The work one pointer event or one display frame costs the layout, counted at the product boundary: a
/// `ShellWindow` wired as the app wires it (its overlay layer adopts the layout's plane, places the divider
/// catcher areas and asks the window's Chromium pages to update), the test as the clock. The layout perf
/// audit's before/after numbers (DividerCatcherMotionTests `dividerDragWorkPerEvent`,
/// StripPanFramePresentationTests `aStripPanFrameOverADockMovesNothingTwice`, which print `WORK` lines).
@MainActor
final class LayoutWorkProbe {
    final class Panes: LayoutPaneContentProvider {
        func makeContentView(for pane: PaneID) -> NSView {
            let view = NSView()
            view.wantsLayer = true
            return view
        }
    }

    /// What one measured step did. `modelWrites` are the turns the model's screens changed in (each one is a
    /// layout sync of the whole snapshot); `hostFrames` the pane hosts whose frame changed; `maskRebuilds` the
    /// rings whose exclusion mask got a new path; `catcherChanges` the steps the window's catcher areas changed
    /// (one window server move per catcher panel while pages show); `pagePosts` the page update requests (each
    /// reaches every Chromium page of the window); `frameRequests` the display link starts asked for.
    struct Counts {
        var modelWrites = 0, reconciles = 0, presentations = 0, chromeUpdates = 0, hostFrames = 0, stripClips = 0
        var maskRebuilds = 0, catcherChanges = 0, pagePosts = 0, frameRequests = 0, ticks = 0, hoverQueries = 0

        static func + (a: Counts, b: Counts) -> Counts {
            Counts(modelWrites: a.modelWrites + b.modelWrites, reconciles: a.reconciles + b.reconciles,
                   presentations: a.presentations + b.presentations, chromeUpdates: a.chromeUpdates + b.chromeUpdates,
                   hostFrames: a.hostFrames + b.hostFrames, stripClips: a.stripClips + b.stripClips,
                   maskRebuilds: a.maskRebuilds + b.maskRebuilds, catcherChanges: a.catcherChanges + b.catcherChanges,
                   pagePosts: a.pagePosts + b.pagePosts, frameRequests: a.frameRequests + b.frameRequests,
                   ticks: a.ticks + b.ticks, hoverQueries: a.hoverQueries + b.hoverQueries)
        }

        /// One `WORK` line: totals over `steps` and the mean per step.
        func line(_ name: String, steps: Int) -> String {
            let fields: [(String, Int)] = [
                ("model_writes", modelWrites), ("reconciles", reconciles), ("presentations", presentations),
                ("chrome_updates", chromeUpdates), ("host_frames", hostFrames), ("strip_clips", stripClips),
                ("mask_rebuilds", maskRebuilds), ("catcher_changes", catcherChanges), ("page_posts", pagePosts),
                ("frame_requests", frameRequests), ("ticks", ticks), ("hover_queries", hoverQueries),
            ]
            let per = fields.map { "\($0.0)=\($0.1) per_step_\($0.0)=\(String(format: "%.2f", Double($0.1) / Double(max(steps, 1))))" }
            return "WORK case=\(name) steps=\(steps) " + per.joined(separator: " ")
        }
    }

    let provider = Panes()
    let model: LayoutModel
    let root: LayoutRootView
    let window: ShellWindow
    private var modelWrites = 0
    private var pagePosts = 0
    private var hoverQueries = 0
    private var observer: (any NSObjectProtocol)?
    /// A still pointer over the layout (window coordinates), as if the window were key and on top there: divider
    /// hover asks the window server whether it is (`hoverQueries`). Nil: no pointer.
    var hoverAt: CGPoint?

    /// `layout` on one screen in a `size` window.
    init(_ layout: ScreenLayout, size: CGSize = CGSize(width: 1600, height: 1000), focused: PaneID) {
        _ = NSApplication.shared
        model = LayoutModel(screens: [LayoutScreen(id: "s", name: "s", layout: layout)], activeScreenID: "s", focusedPane: focused)
        model.followsDesignMetrics = false
        root = LayoutRootView(model: model, contentProvider: provider)
        root.context.reduceMotionOverride = false
        window = ShellWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = root
        root.layoutSubtreeIfNeeded()
        root.driver.isManual = true
        root.context.hoverPointer = { [weak self] _ in self?.hoverAt }
        root.context.hoverReachesWindow = { [weak self] _ in
            self?.hoverQueries += 1
            return true
        }
        // global-notice-allow: CEFHostView observes its window's page update request on the default center (the production path)
        observer = NotificationCenter.default.addObserver(forName: Notification.Name.browserChildWindowPagesNeedUpdate, object: window,
                                                          queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.pagePosts += 1 } // main-proof: posted by the window's overlay layer on main
        }
        watchModel()
        settle()
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        window.close()
    }

    var screen: ScreenContentView { root.screenViews["s"]! }

    /// Counts each turn in which the model's screens changed (the observation the layout syncs on).
    private func watchModel() {
        withObservationTracking { _ = model.screens } onChange: { [weak self] in
            Task { @MainActor in
                self?.modelWrites += 1
                self?.watchModel()
            }
        }
    }

    /// Runs frames until nothing moves (at most 4 s of them).
    @discardableResult
    func settle() -> Int {
        var frames = 0
        while frames < 480, root.advanceFrame(1.0 / 120) { frames += 1 }
        root.layoutSubtreeIfNeeded()
        return frames
    }

    private struct State {
        var hosts: [ObjectIdentifier: CGRect]
        var masks: [ObjectIdentifier: CGPath?]
        var catchers: [CGRect]
        var counts: Counts
    }

    private func state() -> State {
        let hosts = screen.subviews.compactMap { $0 as? PaneHostView }
        return State(hosts: Dictionary(uniqueKeysWithValues: hosts.map { (ObjectIdentifier($0), $0.frame) }),
                     masks: Dictionary(uniqueKeysWithValues: hosts.map { (ObjectIdentifier($0), ($0.chrome.layer?.mask as? CAShapeLayer)?.path) }),
                     catchers: window.overlayLayer.catcherAreas.map(\.rect),
                     counts: Counts(modelWrites: modelWrites, reconciles: screen.reconcilePasses, presentations: screen.presentationPasses,
                                    chromeUpdates: Int(LayoutRootView.paneChromeUpdates), stripClips: screen.stripClipsComputed,
                                    pagePosts: pagePosts, frameRequests: root.driver.startRequests, hoverQueries: hoverQueries))
    }

    /// The work of `body` and of the turn after it: the model's observation turn, then, as the display link
    /// would, one frame tick when anything asked for one (`tick: true` always ticks, a pan's frame), and the
    /// window's layout pass.
    func measure(tick: Bool = false, _ body: () -> Void) async -> Counts {
        let before = state()
        body()
        for _ in 0..<4 { await Task.yield() }
        var ticks = 0
        if tick || root.driver.startRequests > before.counts.frameRequests {
            _ = root.advanceFrame(1.0 / 120)
            ticks = 1
        }
        root.layoutSubtreeIfNeeded()
        let after = state()
        var counts = Counts()
        counts.modelWrites = after.counts.modelWrites - before.counts.modelWrites
        counts.reconciles = after.counts.reconciles - before.counts.reconciles
        counts.presentations = after.counts.presentations - before.counts.presentations
        counts.chromeUpdates = after.counts.chromeUpdates - before.counts.chromeUpdates
        counts.stripClips = after.counts.stripClips - before.counts.stripClips
        counts.pagePosts = after.counts.pagePosts - before.counts.pagePosts
        counts.frameRequests = after.counts.frameRequests - before.counts.frameRequests
        counts.hoverQueries = after.counts.hoverQueries - before.counts.hoverQueries
        counts.ticks = ticks
        counts.hostFrames = after.hosts.filter { before.hosts[$0.key] != $0.value }.count
        counts.maskRebuilds = after.masks.filter { id, path in
            guard let path else { return false }
            return before.masks[id].map { $0 !== path } ?? true
        }.count
        counts.catcherChanges = after.catchers != before.catchers ? 1 : 0
        return counts
    }

    func event(_ type: NSEvent.EventType, _ point: CGPoint, _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}
