public import AppKit
public import CmuxSidebar

/// Owns the transient cursor / hit-band / pointer-monitor state for the two
/// sidebar resizer dividers and keeps the resize cursor stable while the pointer
/// is in a divider band or a drag is in flight.
///
/// ## Why this exists
///
/// Dragging a sidebar divider in `cmux` competes with overlapping AppKit views
/// (notably `WKWebView` and the terminal portal layer) that continuously reassert
/// their own cursor through `cursorUpdate` events. Keeping the resize cursor
/// pinned therefore needs three cooperating mechanisms, all owned here:
/// a local `NSEvent` monitor that consumes hover motion inside the band, a
/// high-frequency stabilizer that re-asserts the cursor, and a deferred release
/// that only pops the cursor once the pointer truly leaves and no button is down.
///
/// ## Isolation design
///
/// Everything here runs on the main actor: it touches `NSCursor`, `NSEvent`, and
/// the live window, all of which are main-thread AppKit APIs, and its callers are
/// SwiftUI view code that already lives on the main actor. The state is transient
/// resize-interaction state, not durable model data, so it lives where its
/// callers live rather than behind an actor (per the refactor's "state lives
/// where its callers live" ruling). The host view is a SwiftUI `struct` that is
/// recreated every render, so the controller never stores a back-reference to it;
/// the host instead supplies a fresh ``SidebarResizerBandInputs`` snapshot (and a
/// provider closure for self-driven updates from the monitor and stabilizer).
///
/// ## Modernization
///
/// The legacy `ContentView` implementation scheduled the cursor release with
/// `DispatchQueue.main.asyncAfter` and ran the stabilizer on a repeating
/// `DispatchSource` timer. Both are replaced here with structured `Task`s driven
/// by an injected `Clock` (`ContinuousClock` in production), per the refactor's
/// `asyncAfter`/`Timer` ban: the cursor release is a bounded auto-dismiss whose
/// cancellation is wired to band state, and the stabilizer is a cancellable
/// re-assert loop. The only observable deltas from the Dispatch versions are the
/// loss of the timer's 2 ms leeway/coalescing (immaterial for a 16 ms cursor
/// re-assert) and that a zero-delay release runs after an `await` suspension
/// rather than a `DispatchQueue.main.async` hop (both defer to the next turn).
@MainActor
public final class SidebarResizerController {
    /// Whether a divider drag is currently in flight.
    public private(set) var isResizerDragging = false

    /// Whether the live pointer currently sits inside a divider hit band.
    public private(set) var isResizerBandActive = false

    /// The drag-start width captured for the leading sidebar divider, or `nil`
    /// when no leading drag is in flight.
    public var sidebarDragStartWidth: CGFloat?

    /// The drag-start width captured for the trailing explorer divider, or `nil`
    /// when no trailing drag is in flight.
    public var fileExplorerDragStartWidth: CGFloat?

    private var hoveredResizerHandles: Set<SidebarResizerHandle> = []
    private var isSidebarResizerCursorActive = false
    private var cursorReleaseTask: Task<Void, Never>?
    private var stabilizerTask: Task<Void, Never>?
    private var pointerMonitor: Any?

    private let bandPolicy: SidebarResizerBandPolicy
    private let fixedSidebarResizeCursor: NSCursor
    private let clock: any Clock<Duration>

    /// Supplies the live window + divider geometry for self-driven band updates
    /// from the pointer monitor and the stabilizer loop. Set by ``attach(bandInputsProvider:)``.
    ///
    /// Deliberately not `@Sendable`: it is stored and invoked only on this
    /// `@MainActor` controller and reads the host view's main-actor state, so no
    /// cross-actor transfer occurs.
    private var bandInputsProvider: (() -> SidebarResizerBandInputs?)?

    /// Creates a resizer controller.
    /// - Parameters:
    ///   - bandPolicy: The pure hit-band geometry, configured with the app's
    ///     divider hit-width constants.
    ///   - fixedSidebarResizeCursor: The resize cursor to pin while resizing.
    ///   - clock: The clock used to schedule the cursor release and stabilizer.
    ///     Defaults to `ContinuousClock`; tests inject a controllable clock.
    public init(
        bandPolicy: SidebarResizerBandPolicy,
        fixedSidebarResizeCursor: NSCursor,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.bandPolicy = bandPolicy
        self.fixedSidebarResizeCursor = fixedSidebarResizeCursor
        self.clock = clock
    }

    /// Attaches the provider the controller calls to re-read live window/divider
    /// geometry when the monitor or stabilizer drives a band update on its own.
    /// - Parameter bandInputsProvider: Returns the current band inputs, or `nil`
    ///   when no window/divider context is available.
    public func attach(bandInputsProvider: @escaping () -> SidebarResizerBandInputs?) {
        self.bandInputsProvider = bandInputsProvider
    }

    // MARK: - Drag lifecycle

    /// Marks a divider drag as started (idempotent).
    public func beginDrag() {
        isResizerDragging = true
    }

    /// Marks a divider drag as ended (idempotent).
    public func endDrag() {
        isResizerDragging = false
    }

    // MARK: - Cursor lifecycle

    /// Pins the resize cursor and cancels any pending release.
    public func activateSidebarResizerCursor() {
        cursorReleaseTask?.cancel()
        cursorReleaseTask = nil
        isSidebarResizerCursorActive = true
        fixedSidebarResizeCursor.set()
    }

    /// Pops the resize cursor back to the arrow when nothing keeps it pinned.
    ///
    /// The cursor stays pinned while a drag is in flight, the pointer is in a
    /// band, a handle is hovered, or the left mouse button is down — unless
    /// `force` overrides those.
    /// - Parameter force: When `true`, releases regardless of the keep-pinned
    ///   conditions.
    public func releaseSidebarResizerCursorIfNeeded(force: Bool = false) {
        let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let shouldKeepCursor = !force
            && (isResizerDragging || isResizerBandActive || !hoveredResizerHandles.isEmpty || isLeftMouseButtonDown)
        guard !shouldKeepCursor else { return }
        guard isSidebarResizerCursorActive else { return }
        isSidebarResizerCursorActive = false
        NSCursor.arrow.set()
    }

    /// Schedules a deferred cursor release after `delay`.
    ///
    /// Replaces the legacy `DispatchQueue.main.asyncAfter` schedule with a
    /// cancellable `Clock`-driven `Task`; the prior pending release is cancelled
    /// so only the latest schedule fires.
    /// - Parameters:
    ///   - force: Passed through to ``releaseSidebarResizerCursorIfNeeded(force:)``.
    ///   - delay: How long to wait before releasing. Zero defers to the next turn.
    public func scheduleSidebarResizerCursorRelease(force: Bool = false, delay: Duration = .zero) {
        cursorReleaseTask?.cancel()
        let task = Task { @MainActor [weak self, clock] in
            do {
                try await clock.sleep(for: delay)
            } catch {
                return
            }
            guard let self else { return }
            self.cursorReleaseTask = nil
            self.releaseSidebarResizerCursorIfNeeded(force: force)
        }
        cursorReleaseTask = task
    }

    // MARK: - Band state

    private func dividerBandContains(
        pointInContent point: NSPoint,
        contentBounds: NSRect,
        inputs: SidebarResizerBandInputs
    ) -> Bool {
        bandPolicy.bandContains(
            point: point,
            contentBounds: contentBounds,
            leftDividerVisible: inputs.leftDividerVisible,
            leftDividerX: inputs.leftDividerX,
            rightDividerVisible: inputs.rightDividerVisible,
            rightDividerX: contentBounds.maxX - inputs.rightSidebarWidth
        )
    }

    /// Recomputes band state and drives the cursor + stabilizer from a fresh
    /// geometry snapshot. Call from the host whenever divider geometry or
    /// visibility changes.
    /// - Parameter inputs: The live window + divider geometry.
    public func updateBandState(inputs: SidebarResizerBandInputs) {
        guard inputs.leftDividerVisible || inputs.rightDividerVisible,
              let window = inputs.window,
              let contentView = window.contentView else {
            isResizerBandActive = false
            scheduleSidebarResizerCursorRelease(force: true)
            return
        }

        // Use live global pointer location instead of per-event coordinates.
        // Overlapping tracking areas (notably WKWebView) can deliver stale/jittery
        // event locations during cursor updates, which causes visible cursor flicker.
        let pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let pointInContent = contentView.convert(pointInWindow, from: nil)
        let isInDividerBand = dividerBandContains(
            pointInContent: pointInContent,
            contentBounds: contentView.bounds,
            inputs: inputs
        )
        isResizerBandActive = isInDividerBand

        if isInDividerBand || isResizerDragging {
            activateSidebarResizerCursor()
            startSidebarResizerCursorStabilizer()
            // AppKit cursorUpdate handlers from overlapped portal/web views can run
            // after our local monitor callback and temporarily reset the cursor.
            // Re-assert on the next runloop turn to keep the resize cursor stable.
            let cursor = fixedSidebarResizeCursor
            Task { @MainActor in
                cursor.set()
            }
        } else {
            stopSidebarResizerCursorStabilizer()
            scheduleSidebarResizerCursorRelease()
        }
    }

    private func updateBandStateFromProvider() {
        guard let inputs = bandInputsProvider?() else {
            isResizerBandActive = false
            scheduleSidebarResizerCursorRelease(force: true)
            return
        }
        updateBandState(inputs: inputs)
    }

    // MARK: - Stabilizer

    /// Starts the high-frequency cursor re-assert loop (idempotent).
    ///
    /// Replaces the legacy 16 ms repeating `DispatchSource` timer with a
    /// cancellable `Clock`-driven loop. Each tick recomputes band state and
    /// re-asserts the cursor; the loop stops itself once nothing keeps the cursor
    /// pinned.
    public func startSidebarResizerCursorStabilizer() {
        guard stabilizerTask == nil else { return }
        let task = Task { @MainActor [weak self, clock, fixedSidebarResizeCursor] in
            while true {
                do {
                    try await clock.sleep(for: .milliseconds(16))
                } catch {
                    return
                }
                guard let self else { return }
                self.updateBandStateFromProvider()
                if self.isResizerBandActive || self.isResizerDragging {
                    fixedSidebarResizeCursor.set()
                } else {
                    self.stopSidebarResizerCursorStabilizer()
                    return
                }
            }
        }
        stabilizerTask = task
    }

    /// Stops the cursor re-assert loop (idempotent).
    public func stopSidebarResizerCursorStabilizer() {
        stabilizerTask?.cancel()
        stabilizerTask = nil
    }

    // MARK: - Pointer monitor

    /// Installs the local `NSEvent` monitor that pins the cursor inside the
    /// divider band (idempotent). Enables mouse-moved events on the window and
    /// runs one initial band update.
    /// - Parameter window: The window to enable mouse-moved events on.
    public func installSidebarResizerPointerMonitorIfNeeded(window: NSWindow?) {
        guard pointerMonitor == nil else { return }
        window?.acceptsMouseMovedEvents = true
        pointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [
                .mouseMoved,
                .mouseEntered,
                .mouseExited,
                .cursorUpdate,
                .appKitDefined,
                .systemDefined,
                .leftMouseDown,
                .leftMouseUp,
                .leftMouseDragged,
            ]
        ) { [weak self] event in
            guard let self else { return event }
            self.updateBandStateFromProvider()
            let shouldOverrideCursorEvent: Bool = {
                switch event.type {
                case .cursorUpdate, .mouseMoved, .mouseEntered, .mouseExited, .appKitDefined, .systemDefined:
                    return true
                default:
                    return false
                }
            }()
            if shouldOverrideCursorEvent, (self.isResizerBandActive || self.isResizerDragging) {
                // Consume hover motion in divider band so overlapped views cannot
                // continuously reassert their own cursor while we are resizing.
                self.activateSidebarResizerCursor()
                self.fixedSidebarResizeCursor.set()
                return nil
            }
            return event
        }
        updateBandStateFromProvider()
    }

    /// Removes the local `NSEvent` monitor, clears cursor/band state, stops the
    /// stabilizer, and forces a cursor release.
    public func removeSidebarResizerPointerMonitor() {
        if let monitor = pointerMonitor {
            NSEvent.removeMonitor(monitor)
            pointerMonitor = nil
        }
        isResizerBandActive = false
        isSidebarResizerCursorActive = false
        stopSidebarResizerCursorStabilizer()
        scheduleSidebarResizerCursorRelease(force: true)
    }

    // MARK: - Handle hover

    /// Records that `handle` is hovered and pins the resize cursor.
    /// - Parameter handle: The handle now under the pointer.
    public func handleHoverBegan(_ handle: SidebarResizerHandle) {
        hoveredResizerHandles.insert(handle)
        activateSidebarResizerCursor()
    }

    /// Records that `handle` is no longer hovered, keeping or scheduling release
    /// of the cursor depending on whether a button is down.
    /// - Parameter handle: The handle the pointer left.
    public func handleHoverEnded(_ handle: SidebarResizerHandle) {
        hoveredResizerHandles.remove(handle)
        let isLeftMouseButtonDown = CGEventSource.buttonState(.combinedSessionState, button: .left)
        if isLeftMouseButtonDown {
            // Keep resize cursor pinned through mouse-down so AppKit
            // cursorUpdate events from overlapping views do not flash arrow.
            activateSidebarResizerCursor()
        } else {
            // Give mouse-down + drag-start callbacks time to establish state
            // before any cursor pop is attempted.
            scheduleSidebarResizerCursorRelease(delay: .milliseconds(50))
        }
    }

    /// Clears hover tracking for `handle` and resets band/drag state when a
    /// handle overlay disappears.
    /// - Parameter handle: The handle whose overlay is going away.
    public func handleDidDisappear(_ handle: SidebarResizerHandle) {
        hoveredResizerHandles.remove(handle)
        isResizerBandActive = false
    }
}
