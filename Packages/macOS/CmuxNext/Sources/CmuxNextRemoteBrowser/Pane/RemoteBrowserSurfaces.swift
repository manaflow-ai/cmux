public import AppKit
public import CmuxNextRemoteView

#if DEBUG
/// The popup surfaces of one remote tab (`rb.surface.show/update/hide`,
/// RT5): each is a borderless child view over the page at its CSS anchor
/// (page points are CSS pixels), with its own `RemoteBrowserPane` (decoder
/// and presenter) on its own rd stream. The host sizes the page's screen to
/// the pane, so Chromium keeps popups inside the page.
///
/// Popup surfaces take pointer input only (cmux-remote-browser `rp_input`):
/// pointer events go out named by the surface, in its own CSS pixels; keys
/// go to the page, which routes them to the open popup.
@MainActor
public final class RemoteBrowserSurfaces {
    private let page: RemoteBrowserContentView
    private let source: @MainActor (UInt16) -> any RemoteViewStreamSource
    private let send: @MainActor (RemoteRdJSON, Bool) -> Void
    private var open: [UInt32: Surface] = [:]

    /// `source` gives a surface stream's units; `send` sends one rb input
    /// event (`mustDeliver` second).
    public init(
        page: RemoteBrowserContentView, source: @escaping @MainActor (UInt16) -> any RemoteViewStreamSource,
        send: @escaping @MainActor (RemoteRdJSON, Bool) -> Void
    ) {
        self.page = page
        self.source = source
        self.send = send
    }

    /// The open surfaces, ascending.
    public var surfaceIDs: [UInt32] { open.keys.sorted() }

    public func apply(_ message: RbSurfaceMessage) {
        switch message {
        case let .show(surface, stream, kind, anchor, _, _):
            // A show of an open surface (a new size) replaces it: its stream changed.
            remove(surface)
            let pane = RemoteBrowserPane(source: source(stream))
            let input = SurfaceInput(owner: self, page: page, surface: surface)
            input.view = pane.view
            pane.view.eventTarget = input
            pane.view.frame = anchor
            page.addSubview(pane.view)
            open[surface] = Surface(pane: pane, input: input, kind: kind)
            pane.start()
        case let .update(surface, anchor, _, _):
            if let view = open[surface]?.pane.view { view.frame = anchor }
        case let .hide(surface):
            remove(surface)
        }
    }

    /// The session ended or closed: every surface goes.
    public func closeAll() {
        for surface in open.keys { remove(surface) }
    }

    package func view(of surface: UInt32) -> RemoteBrowserContentView? {
        open[surface]?.pane.view
    }

    /// The host's kind string of an open surface (`page_popup`, `autofill`,
    /// `extension_popup`, `bubble`).
    package func kind(of surface: UInt32) -> String? {
        open[surface]?.kind
    }

    /// Sends a pointer event at `point` (the surface's CSS pixels) to
    /// `surface`; dropped once the surface is gone.
    public func sendPointer(_ event: NSEvent, at point: CGPoint, surface: UInt32) {
        guard open[surface] != nil, let json = RemoteBrowserInputEncoder.pointer(event, at: point, surface: surface) else { return }
        send(json, RemoteBrowserInputEncoder.mustDeliver(event))
    }

    private func remove(_ surface: UInt32) {
        guard let gone = open.removeValue(forKey: surface) else { return }
        gone.pane.stop()
        let view = gone.pane.view
        // A click made the popup first responder: the page keeps the keys.
        if let window = view.window, window.firstResponder === view { window.makeFirstResponder(page) }
        view.removeFromSuperview()
    }

    private struct Surface {
        let pane: RemoteBrowserPane
        let input: SurfaceInput
        let kind: String
    }
}

/// One surface view's events: pointers to the surface, keys to the page.
@MainActor
private final class SurfaceInput: RemoteBrowserEventTarget {
    private weak var owner: RemoteBrowserSurfaces?
    private weak var page: RemoteBrowserContentView?
    weak var view: RemoteBrowserContentView?
    private let surface: UInt32

    init(owner: RemoteBrowserSurfaces, page: RemoteBrowserContentView, surface: UInt32) {
        self.owner = owner
        self.page = page
        self.surface = surface
    }

    func handleKeyEquivalent(_ event: NSEvent) -> Bool {
        page?.eventTarget?.handleKeyEquivalent(event) ?? false
    }

    func handleKey(_ event: NSEvent) {
        page?.eventTarget?.handleKey(event)
    }

    func handlePointer(_ event: NSEvent) {
        guard let view else { return }
        owner?.sendPointer(event, at: view.convert(event.locationInWindow, from: nil), surface: surface)
    }
}
#endif
