import AppKit
import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import CmuxSwiftRenderUI
import Observation
import SwiftUI

/// The render worker's main-actor state machine: owns the offscreen surface
/// (window + `NSHostingView`), the shared remote context, the watched sidebar
/// file, and the interpreter, and applies host messages strictly in arrival
/// order.
///
/// Rendering model (spike-verified): the hosting view's backing layer is the
/// remote context's root and the window is **never ordered in**, so SwiftUI
/// has no display-link driver. Every state change therefore flows through an
/// explicit pump — mutate `rootView`, force layout, commit — which is exactly
/// right for a sidebar that only changes when the host sends data, the file
/// changes on disk, or a forwarded pointer event lands.
@MainActor
final class RenderWorkerCoordinator {
    private let channel: LengthPrefixedMessageChannel
    private let encoder = JSONEncoder()
    /// Parse-caching interpreter (same engine and fault-injection hooks as the
    /// stage-1 interpreter worker).
    private let runner = RenderInterpreterRunner()

    private var remoteContext: RemoteRenderContext?
    private var window: RemoteWorkerWindow?
    private var hosting: NSHostingView<RemoteWorkerRootView>?
    /// Tappable regions of the current render, in the root coordinate space
    /// (top-left origin), refreshed by the root view's preference observer.
    private var tapTargets: [SidebarTapTarget] = []

    /// Loads and watches the sidebar file (hot reload), reusing the exact
    /// in-process semantics.
    private var model: CustomSidebarModel?
    /// The scene's file path as sent by the host. Tracked separately from
    /// `model.fileURL`, which the model may re-resolve to a sibling extension
    /// (`name.swift` <-> `name.json`).
    private var scenePath: String?
    private var dataState: [String: SwiftValue] = [:]
    private var insets = CustomSidebarContentInsets.zero
    private var geometry = RenderSurfaceGeometry(width: 280, height: 600, scale: 2)
    private var swiftRender: RenderNode?
    private var hasRendered = false
    /// The most recent file state that produced a working view, kept so a
    /// broken mid-edit save (or an atomic save's transient delete) does NOT
    /// replace a working sidebar. Reset when the selected file changes.
    private var lastGoodState: CustomSidebarModel.State?
    private var lastGoodRender: RenderNode?

    /// Sends interpreted-button actions back to the host for dispatch.
    private lazy var dispatch = SidebarActionDispatch { [weak self] action in
        self?.send(.action(action))
    }

    init(channel: LengthPrefixedMessageChannel) {
        self.channel = channel
        ensureSurface()
    }

    /// Stderr diagnostics, enabled with `CMUX_RENDER_WORKER_DEBUG=1` in the
    /// worker environment (inherited from the host). The worker has no log
    /// sink of its own; stderr lands in the host's console/session log.
    private let debugEnabled = ProcessInfo.processInfo.environment["CMUX_RENDER_WORKER_DEBUG"] == "1"

    private func debugLog(_ message: @autoclosure () -> String) {
        guard debugEnabled else { return }
        FileHandle.standardError.write(Data("render-worker: \(message())\n".utf8))
    }

    /// Applies one host message. Called from a single FIFO consumer, so
    /// ordering matches the wire.
    func handle(_ message: RenderWorkerInbound) {
        switch message {
        case let .scene(scene):
            apply(scene)
            send(.ack(scene.seq))
        case let .resize(geometry):
            apply(geometry)
        case let .pointer(event):
            deliver(event)
            pump()
        case let .reloadSidebars(names):
            // Forwarded from the host's CLI reload notification; the model's
            // state change re-renders via the observation hook.
            model?.requestReload(names: names)
        }
    }

    // MARK: - Surface

    private func ensureSurface() {
        guard window == nil else { return }
        guard let context = RemoteRenderContext() else { return }
        remoteContext = context

        let frame = NSRect(x: 0, y: 0, width: geometry.width, height: geometry.height)
        let hosting = NSHostingView(rootView: currentContent())
        // The host dictates the surface size; don't let SwiftUI fight it.
        hosting.sizingOptions = []
        hosting.frame = frame

        let window = RemoteWorkerWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        hosting.wantsLayer = true

        self.window = window
        self.hosting = hosting

        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        // Re-parent the backing layer as the remote context's root. The window
        // stays offscreen forever, so no window context competes for it.
        context.layer = hosting.layer
        CATransaction.flush()
        debugLog("surface ready: contextId=\(context.contextId)")

        send(.context(context.contextId))
    }

    // MARK: - Scene / geometry

    private func apply(_ scene: RenderScene) {
        ensureSurface()
        dataState = scene.state
        insets = CustomSidebarContentInsets(top: scene.topInset, bottom: scene.bottomInset)

        if scenePath != scene.filePath {
            scenePath = scene.filePath
            let url = URL(fileURLWithPath: scene.filePath)
            model?.stop()
            swiftRender = nil
            hasRendered = false
            lastGoodState = nil
            lastGoodRender = nil
            let model = CustomSidebarModel(fileURL: url)
            self.model = model
            model.start()
            observe(model)
        }
        refresh()
    }

    private func apply(_ geometry: RenderSurfaceGeometry) {
        ensureSurface()
        self.geometry = geometry
        guard let window, let hosting else { return }
        let size = NSSize(width: geometry.width, height: geometry.height)
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        pump()
    }

    /// Re-arms Observation on the model so disk reloads (kqueue → model state
    /// change) re-render and pump even though no SwiftUI view observes the
    /// model in this process.
    private func observe(_ model: CustomSidebarModel) {
        withObservationTracking {
            _ = model.state
            _ = model.sourceRevision
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.model === model else { return }
                self.refresh()
                self.observe(model)
            }
        }
    }

    /// Re-interprets (when showing Swift source) and republishes the root
    /// view, then pumps a commit so the host sees it.
    ///
    /// Hot reload is **last-good sticky**: a save only replaces what's on
    /// screen when it actually interprets to a view (or decodes, for JSON).
    /// Broken intermediate saves — the editor writing mid-edit states, or an
    /// atomic save's transient missing file — keep the previous working
    /// render. Error states still show when a file is broken from the start
    /// (no good version to fall back to).
    private func refresh() {
        guard let model, let hosting else { return }
        var displayState = model.state
        switch model.state {
        case let .swiftSource(source):
            let response = runner.run(InterpreterRequest(id: 0, source: source, state: dataState))
            if let node = response.node {
                swiftRender = node
                hasRendered = true
                lastGoodState = model.state
                lastGoodRender = node
            } else if let lastGoodState {
                displayState = lastGoodState
                // Keep live data flowing while the on-disk file is broken:
                // re-interpret the last GOOD source against the fresh data
                // context (falling back to the cached render if even that
                // stops producing a view).
                if case let .swiftSource(goodSource) = lastGoodState,
                   let liveNode = runner.run(InterpreterRequest(id: 0, source: goodSource, state: dataState)).node {
                    swiftRender = liveNode
                    lastGoodRender = liveNode
                } else {
                    swiftRender = lastGoodRender
                }
            } else {
                swiftRender = nil
                hasRendered = true
            }
        case .json:
            lastGoodState = model.state
            lastGoodRender = nil
        case .missing, .failed:
            if let lastGoodState {
                displayState = lastGoodState
                swiftRender = lastGoodRender
            }
        }
        hosting.rootView = currentContent(state: displayState)
        pump()
    }

    private func currentContent(state: CustomSidebarModel.State? = nil) -> RemoteWorkerRootView {
        RemoteWorkerRootView(
            content: CustomSidebarContentView(
                state: state ?? model?.state ?? .missing,
                swiftRender: swiftRender,
                hasRenderedSwift: hasRendered,
                dispatch: dispatch,
                contentInsets: insets
            ),
            onTapTargetsChange: { [weak self] targets in
                self?.tapTargets = targets
            }
        )
    }

    /// Forces the offscreen view tree through layout and commits the layer
    /// tree to the window server. The explicit flush is the worker's display
    /// driver — there is no on-screen window to drive one.
    private func pump() {
        guard let window, let hosting else { return }
        window.layoutIfNeeded()
        hosting.layoutSubtreeIfNeeded()
        if let layer = hosting.layer, geometry.scale != 1 {
            applyContentsScale(layer, scale: CGFloat(geometry.scale))
        }
        // AppKit re-parents the contentView's backing layer back into the
        // window's frame-view layer tree on every window layout pass, which
        // silently detaches it from the remote context (the never-shown window
        // has no render destination, so the host goes blank). Steal it back
        // after layout, before committing.
        if let layer = hosting.layer, let remoteContext, remoteContext.layer !== layer {
            layer.removeFromSuperlayer()
            remoteContext.layer = layer
        }
        CATransaction.flush()
    }

    // MARK: - Input

    private func deliver(_ event: RenderPointerEvent) {
        guard let hosting else { return }
        let location = NSPoint(x: event.x, y: event.y)
        switch event.kind {
        case .scroll:
            scroll(by: event, at: location, in: hosting)
        case .up:
            // Geometric activation: forwarded clicks are hit-tested against
            // the rendered tree's reported tap targets. Synthesized NSEvents
            // route correctly (verified down to the SwiftUI container view)
            // but SwiftUI control gestures never fire in a never-on-screen
            // window, and its AX tree only materializes for assistive
            // clients — the registry is deterministic and testable instead.
            press(at: location)
        case .down, .drag:
            // The press fires on up; an in-progress press has no offscreen
            // visual feedback to drive.
            break
        }
    }

    /// Fires the innermost tap target containing `location` (window coords,
    /// bottom-left origin), sending its action to the host.
    private func press(at location: NSPoint) {
        // Tap targets are in the root view's top-left-origin space.
        let point = CGPoint(x: location.x, y: CGFloat(geometry.height) - location.y)
        let hit = tapTargets
            .filter { $0.frame.contains(point) }
            .min { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
        guard let hit else {
            debugLog("press: no tap target at \(point) targets=\(tapTargets.map { "\($0.frame)" }.joined(separator: " | "))")
            return
        }
        debugLog("press: firing action at \(point)")
        send(.action(hit.action))
    }

    /// Scrolls the deepest `NSScrollView` under the point directly. SwiftUI's
    /// macOS `ScrollView` is `NSScrollView`-backed, so adjusting the clip
    /// view's origin is the reliable windowless equivalent of a wheel event.
    private func scroll(by event: RenderPointerEvent, at location: NSPoint, in hosting: NSView) {
        guard let scrollView = scrollView(at: location, in: hosting) else { return }
        let clip = scrollView.contentView
        var target = clip.bounds
        let isFlipped = scrollView.documentView?.isFlipped ?? true
        // Natural scrolling deltas: positive deltaY means content moves down
        // (reveal earlier content).
        if isFlipped {
            target.origin.y -= CGFloat(event.deltaY)
        } else {
            target.origin.y += CGFloat(event.deltaY)
        }
        target.origin.x -= CGFloat(event.deltaX)
        // Clamp through the clip view itself: the resting origin is NOT (0,0)
        // when SwiftUI applies safe-area insets (it is -topInset), so a naive
        // max(0, …) clamp pins content up under the host's titlebar chrome and
        // never lets it scroll back. constrainBoundsRect honors content
        // insets and the document bounds exactly like a real wheel event.
        let constrained = clip.constrainBoundsRect(target)
        clip.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func scrollView(at location: NSPoint, in root: NSView) -> NSScrollView? {
        // `location` is in window coords; the hosting view fills a borderless
        // window at origin zero, so its superview (frame view) space matches.
        guard let hit = root.hitTest(location) else {
            return firstScrollView(in: root)
        }
        var view: NSView? = hit
        while let current = view {
            if let scrollView = current as? NSScrollView { return scrollView }
            view = current.superview
        }
        return firstScrollView(in: root)
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView { return scrollView }
        for subview in view.subviews {
            if let found = firstScrollView(in: subview) { return found }
        }
        return nil
    }

    // MARK: - Outbound

    private func send(_ message: RenderWorkerOutbound) {
        guard let data = try? encoder.encode(message) else { return }
        try? channel.sendMessage(data)
    }
}

/// Recursively pins `contentsScale` so text and shapes rasterize crisply for
/// the host's screen; the offscreen window has no screen to derive it from.
/// Only touched layers are redisplayed.
@MainActor
private func applyContentsScale(_ layer: CALayer, scale: CGFloat) {
    if layer.contentsScale != scale {
        layer.contentsScale = scale
        layer.setNeedsDisplay()
    }
    if let sublayers = layer.sublayers {
        for sublayer in sublayers {
            applyContentsScale(sublayer, scale: scale)
        }
    }
}
