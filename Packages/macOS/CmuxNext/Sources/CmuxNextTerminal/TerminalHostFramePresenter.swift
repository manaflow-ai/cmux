import CmuxNextCompat
import CoreGraphics
import GhosttyNextKit
import QuartzCore

/// Puts each resized terminal's frame at its new size into the Core Animation commit that carries the
/// size, when the renderer thread has drawn it by then, and never waits for it
/// (ghostty-integration-DESIGN.md G1; feature `terminalPreCommitPresent`).
///
/// A host-sized Ghostty surface draws a new size's frame on its renderer thread, text reflowed, and
/// presents it itself when it completes. When the turn's own display work outlasts that draw (a STRESS
/// layout, many terminals), the commit can already show the frame. Terminals resized in a transaction are
/// collected here, and one pre-commit handler of that transaction asks each for the frame it has
/// (`ghostty_surface_present_host_frame`): only a drawn frame goes in; one not drawn yet lands when it
/// completes. Ghostty orders both writers' frames by one sequence, so this present never shows a frame
/// older than the renderer's. Chromium's browser compositor does the same at a resize: it embeds the
/// newest frame the renderer submitted and never blocks the UI thread on the new size's frame
/// (content/browser/renderer_host/delegated_frame_host.cc, `EmbedSurface`).
///
/// Most resizes come from AppKit's layout, which runs inside Core Animation's commit (the display
/// cycle): a run-loop observer added then would run after that commit, and macOS has no public
/// `CATransaction` commit handler. So the pass runs in the commit's own layer display
/// (``MainCommitDisplayHook``, joined to the resized terminal's window): after AppKit's layout and
/// display, before the encode. That also covers a resize made outside the display cycle: its implicit
/// transaction commits at the end of the turn.
///
/// The hook asks for a display only in a transaction with a resized terminal: nothing runs at rest.
public final class TerminalHostFramePresenter {
    /// Runs `body` once, ahead of the commit of the transaction open now that carries `host`'s tree.
    typealias Schedule = @MainActor (_ host: CALayer, _ body: @escaping @MainActor () -> Void) -> Void

    private let schedule: Schedule
    /// Each resized terminal's present, by the terminal; each captures its terminal weakly.
    private var pending: [ObjectIdentifier: @MainActor () -> Void] = [:]
    /// The host of the pass scheduled and not run yet; nil when none is. A resize in another window
    /// schedules there again, so a window that commits nothing never holds the others' pass back.
    private weak var scheduledHost: CALayer?
    private var scheduled = false
    /// The longest main-thread time one pass took (diagnostics and tests).
    private(set) var longestPass: Duration = .zero
    /// Passes run, and presents they made (diagnostics and tests).
    private(set) var passes = 0
    private(set) var presents = 0

    /// - Parameter schedule: runs a pass once, ahead of the commit that carries the new sizes; nil: inside
    ///   that commit's layer display (``MainCommitDisplayHook``). Tests run passes themselves.
    init(schedule: Schedule? = nil) {
        if let schedule {
            self.schedule = schedule
        } else {
            let hook = MainCommitDisplayHook()
            self.schedule = { host, body in hook.run(in: host, body) }
        }
    }

    /// Whether the pinned GhosttyNextKit's present never waits (`GHOSTTY_PRESENT_NEVER_WAITS`, Package.swift).
    nonisolated static var presentNeverWaits: Bool {
        #if GHOSTTY_PRESENT_NEVER_WAITS
        true
        #else
        false
        #endif
    }

    /// A presenter when ``presentNeverWaits``; nil otherwise: the earlier present held the main thread up
    /// to 4 ms per drag frame. The composition root sets it on ``GhosttyRuntime/hostFramePresenter``.
    public static func makeIfPresentNeverWaits() -> TerminalHostFramePresenter? {
        presentNeverWaits ? TerminalHostFramePresenter() : nil
    }

    /// `view` got a new size (or was shown again): its drawn frame goes into the commit that carries it.
    /// A view outside a window is in no commit: its frame lands when drawn.
    func sizeChanged(of view: TerminalSurfaceView) {
        guard let host = view.window?.contentView?.layer else { return }
        sizeChanged(of: view, in: host) { [weak view] in
            if let view { Self.presentDrawnFrame(of: view) }
        }
    }

    /// `owner`, in `host`'s layer tree, got a new size: `present` runs once ahead of the commit of the
    /// open transaction (the latest one given for `owner`).
    func sizeChanged(of owner: AnyObject, in host: CALayer, present: @escaping @MainActor () -> Void) {
        pending[ObjectIdentifier(owner)] = present
        guard !scheduled || scheduledHost !== host else { return }
        scheduled = true
        scheduledHost = host
        schedule(host) { [weak self] in self?.presentPending() }
    }

    /// One pass: each terminal resized since the last pass presents the frame it has.
    func presentPending() {
        scheduled = false
        scheduledHost = nil
        let start = ContinuousClock.now
        let due = Array(pending.values)
        pending.removeAll(keepingCapacity: true)
        for present in due { present() }
        passes += 1
        presents += due.count
        longestPass = max(longestPass, start.duration(to: .now))
    }

    private static func presentDrawnFrame(of view: TerminalSurfaceView) {
        #if GHOSTTY_PRESENT_NEVER_WAITS
        guard let surface = view.surface else { return }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface). Since p03-rendering-084 it never waits.
        _ = unsafe ghostty_surface_present_host_frame(surface)
        #endif
    }

    /// `ghostty_surface_set_size` of `view`'s live surface; a changed size queues the drawn frame for this
    /// turn's commit when `presenter` exists.
    static func setSize(of view: TerminalSurfaceView, to pixels: CGSize,
                        presenter: TerminalHostFramePresenter? = GhosttyRuntime.shared.hostFramePresenter) {
        guard let surface = view.surface else { return }
        let width = UInt32(pixels.width), height = UInt32(pixels.height)
        var previous: ghostty_surface_size_s?
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        if presenter != nil { previous = unsafe ghostty_surface_size(surface) }
        // SAFETY: as above.
        unsafe ghostty_surface_set_size(surface, width, height)
        guard let presenter, let previous, previous.width_px != width || previous.height_px != height else { return }
        presenter.sizeChanged(of: view)
    }

    /// `ghostty_surface_set_occlusion` of `view`'s live surface; a surface shown again counts as a size
    /// change (ghostty.h), so its drawn frame is queued for this turn's commit when `presenter` exists.
    static func setOcclusion(of view: TerminalSurfaceView, visible: Bool,
                             presenter: TerminalHostFramePresenter? = GhosttyRuntime.shared.hostFramePresenter) {
        guard let surface = view.surface else { return }
        // SAFETY: the view's live surface (TerminalSurfaceView.surface).
        unsafe ghostty_surface_set_occlusion(surface, visible)
        if visible { presenter?.sizeChanged(of: view) }
    }
}
