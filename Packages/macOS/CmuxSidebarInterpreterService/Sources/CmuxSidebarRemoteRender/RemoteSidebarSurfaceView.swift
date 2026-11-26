import AppKit
import CmuxSidebarInterpreterClient
import CmuxSwiftRender
import CmuxSwiftRenderUI
import QuartzCore

/// The host-side AppKit surface for a remotely rendered custom sidebar:
/// displays the worker's layer tree via a hosted remote layer and forwards
/// pointer interactions back over the worker channel.
///
/// Nothing derived from the sidebar file exists in this view — it holds a
/// `CALayerHost` pointing at the worker's context id and a pipe. Worker
/// crashes surface as a fresh `.context` event; the view swaps the hosted
/// layer and the sidebar reappears.
@MainActor
final class RemoteSidebarSurfaceView: NSView {
    private let client: RenderWorkerClient
    /// Runs interpreted-button actions on the host command surface.
    var dispatch: SidebarActionDispatch = .noop

    private var hostedLayer: CALayer?
    private var eventsTask: Task<Void, Never>?
    private var outboxTask: Task<Void, Never>?
    private var reloadObserver: NSObjectProtocol?
    private var windowCloseObserver: NSObjectProtocol?
    private let outbox: AsyncStream<RenderWorkerInbound>.Continuation
    private var lastPushedScene: PushedScene?

    init(client: RenderWorkerClient) {
        self.client = client
        let (stream, continuation) = AsyncStream.makeStream(of: RenderWorkerInbound.self)
        self.outbox = continuation
        super.init(frame: .zero)
        wantsLayer = true

        // Adopt the live worker's layer synchronously so a remounting surface
        // (provider switches, sidebar toggles) shows the last rendered frame
        // immediately; the subscription below swaps in any newer context.
        if let contextId = client.contextCache.contextId {
            adopt(contextId: contextId)
        }

        // Single ordered pipe to the actor: synchronous yields from the main
        // thread keep scene/geometry/pointer ordering intact (independent
        // `Task { await client... }` hops would not guarantee FIFO).
        outboxTask = Task { [client] in
            for await message in stream {
                switch message {
                case let .scene(scene):
                    await client.updateScene(
                        filePath: scene.filePath,
                        state: scene.state,
                        topInset: scene.topInset,
                        bottomInset: scene.bottomInset
                    )
                case let .resize(geometry):
                    await client.resize(geometry)
                case let .pointer(event):
                    await client.forward(event)
                case let .reloadSidebars(names):
                    await client.requestReload(names: names)
                }
            }
        }

        // The CLI's `sidebar reload` posts a host-process notification; the
        // worker can't observe it across the process boundary, so forward it.
        // Token-based observer (same pattern as CustomSidebarModel): the
        // notifications async stream trips CI Swift 6.1's non-Sendable
        // `Notification` check from any actor-adjacent context.
        reloadObserver = NotificationCenter.default.addObserver(
            forName: .customSidebarReloadRequested,
            object: nil,
            queue: .main
        ) { [outbox] notification in
            let names = notification.userInfo?["names"] as? [String]
            outbox.yield(.reloadSidebars(names))
        }

        eventsTask = Task { @MainActor [weak self, client] in
            for await event in await client.subscribe() {
                guard let self else { return }
                switch event {
                case let .context(contextId):
                    self.adopt(contextId: contextId)
                case let .action(action):
                    self.dispatch.run(action)
                }
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Stops the event/outbox pipes. Call from the representable's dismantle;
    /// the worker itself stays alive for the next mount (cheap, and keeps
    /// provider switches snappy).
    func teardown() {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        if let reloadObserver {
            NotificationCenter.default.removeObserver(reloadObserver)
            self.reloadObserver = nil
        }
        eventsTask?.cancel()
        eventsTask = nil
        outboxTask?.cancel()
        outboxTask = nil
        outbox.finish()
    }

    // MARK: - Scene pushes (from the representable)

    /// Sends the current scene when anything in it actually changed.
    func pushScene(
        filePath: String,
        state: [String: SwiftValue],
        insets: CustomSidebarContentInsets
    ) {
        let scene = PushedScene(filePath: filePath, state: state, insets: insets)
        guard scene != lastPushedScene else { return }
        lastPushedScene = scene
        // seq is assigned by the client; 0 here is a placeholder the client
        // overwrites via its own counter.
        outbox.yield(.scene(RenderScene(
            seq: 0,
            filePath: filePath,
            state: state,
            topInset: insets.top,
            bottomInset: insets.bottom
        )))
    }

    // MARK: - Geometry

    override func layout() {
        super.layout()
        hostedLayer?.frame = bounds
        pushGeometry()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        pushGeometry()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pushGeometry()
        armWindowCloseReaper()
    }

    /// Terminates the worker when this surface's window closes. Provider
    /// switches and sidebar toggles keep the worker warm (the client outlives
    /// the surface), so without this a closed window's worker would idle until
    /// app exit.
    private func armWindowCloseReaper() {
        if let windowCloseObserver {
            NotificationCenter.default.removeObserver(windowCloseObserver)
            self.windowCloseObserver = nil
        }
        guard let window else { return }
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [client] _ in
            Task { await client.shutdown() }
        }
    }

    private func pushGeometry() {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let scale = window?.backingScaleFactor ?? 2
        outbox.yield(.resize(RenderSurfaceGeometry(
            width: bounds.width,
            height: bounds.height,
            scale: scale
        )))
    }

    private func adopt(contextId: UInt32) {
        hostedLayer?.removeFromSuperlayer()
        guard let remote = makeRemoteHostedLayer(contextId: contextId) else { return }
        remote.frame = bounds
        layer?.addSublayer(remote)
        hostedLayer = remote
    }

    // MARK: - Input forwarding

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        forward(event, kind: .down)
    }

    override func mouseDragged(with event: NSEvent) {
        forward(event, kind: .drag)
    }

    override func mouseUp(with event: NSEvent) {
        forward(event, kind: .up)
    }

    override func scrollWheel(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        outbox.yield(.pointer(RenderPointerEvent(
            kind: .scroll,
            x: location.x,
            y: surfaceY(location),
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY
        )))
    }

    private func forward(_ event: NSEvent, kind: RenderPointerEvent.Kind) {
        let location = convert(event.locationInWindow, from: nil)
        outbox.yield(.pointer(RenderPointerEvent(
            kind: kind,
            x: location.x,
            y: surfaceY(location),
            clickCount: event.clickCount
        )))
    }

    /// Worker window coordinates are bottom-left-origin points of a window
    /// exactly this view's size, so only a flip (if any) is needed.
    private func surfaceY(_ point: NSPoint) -> CGFloat {
        isFlipped ? bounds.height - point.y : point.y
    }
}

/// Equality snapshot of the last pushed scene, so per-frame SwiftUI updates
/// don't spam identical scenes over the pipe.
private struct PushedScene: Equatable {
    let filePath: String
    let state: [String: SwiftValue]
    let insets: CustomSidebarContentInsets
}
