public import Foundation
public import Observation

/// The state of a browser panel's zoom chip and its popover (Chrome's zoom bubble).
///
/// The chip shows while the page zoom differs from the default zoom setting. Zoom shortcuts
/// open the popover, which closes by itself 1.5 seconds later; pressing one of its buttons
/// keeps it 5 seconds; it stays while the pointer is over it (Chrome `zoom_bubble_view.cc`).
/// Clicking the chip opens the popover until the user dismisses it.
///
/// ```swift
/// let zoom = BrowserZoomIndicatorModel(defaultFactor: 1, clock: ContinuousClock())
/// zoom.update(factor: 1.25)       // chip appears: "125%"
/// zoom.showAfterShortcut()        // popover for 1.5 s
/// ```
@MainActor
@Observable
public final class BrowserZoomIndicatorModel {
    /// How long the popover stays after a zoom shortcut.
    public static let shortcutDuration: Duration = .milliseconds(1500)
    /// How long the popover stays after one of its buttons is pressed.
    public static let buttonDuration: Duration = .seconds(5)

    /// The page's zoom factor.
    public private(set) var factor: Double
    /// The default zoom factor (`browser.defaultZoomLevel`); the chip hides at it.
    public var defaultFactor: Double
    /// Whether the popover is open.
    public private(set) var isPopoverShown = false
    /// Whether the pointer is over the popover; while it is, the popover never closes by itself.
    public var isHovered = false {
        didSet {
            guard isHovered != oldValue else { return }
            if isHovered {
                dismissTask?.cancel()
                dismissTask = nil
            } else if isPopoverShown, let lastDuration {
                scheduleDismiss(after: lastDuration)
            }
        }
    }

    @ObservationIgnored private let clock: any Clock<Duration>
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var lastDuration: Duration?

    /// Creates a model.
    /// - Parameters:
    ///   - factor: The page's zoom factor. Defaults to `1`.
    ///   - defaultFactor: The default zoom factor.
    ///   - clock: The clock auto-dismiss waits on; tests pass a manual clock.
    public init(factor: Double = 1, defaultFactor: Double, clock: any Clock<Duration>) {
        self.factor = factor
        self.defaultFactor = defaultFactor
        self.clock = clock
    }

    /// Whether the chip shows: the zoom differs from the default.
    public var isChipVisible: Bool { abs(factor - defaultFactor) > 0.001 || isPopoverShown }

    /// The chip and popover label, e.g. 125 for 1.25.
    public var percent: Int { BrowserZoomLadder.percent(factor) }

    /// Records the page's zoom.
    /// - Parameter factor: The zoom factor.
    public func update(factor: Double) {
        self.factor = factor
    }

    /// Opens the popover after a zoom shortcut (Cmd-+, Cmd--, Cmd-0); it closes after
    /// ``shortcutDuration`` unless hovered.
    public func showAfterShortcut() {
        show(for: Self.shortcutDuration)
    }

    /// Keeps the popover open after one of its buttons was pressed; it closes after
    /// ``buttonDuration`` unless hovered.
    public func noteButtonPress() {
        show(for: Self.buttonDuration)
    }

    /// Opens the popover from a chip click; it stays until dismissed.
    public func showFromChip() {
        dismissTask?.cancel()
        dismissTask = nil
        lastDuration = nil
        isPopoverShown = true
    }

    /// Closes the popover.
    public func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        lastDuration = nil
        isPopoverShown = false
    }

    private func show(for duration: Duration) {
        isPopoverShown = true
        lastDuration = duration
        if !isHovered { scheduleDismiss(after: duration) }
    }

    private func scheduleDismiss(after duration: Duration) {
        dismissTask?.cancel()
        // The deadline is fixed now, not when the task first runs.
        let sleep = Self.sleeper(clock, for: duration)
        // A bounded, cancellable auto-dismiss delay (the intended behavior, not synchronization).
        dismissTask = Task { [weak self] in
            do {
                try await sleep()
            } catch {
                return
            }
            self?.autoDismiss()
        }
    }

    /// Waits for a scheduled auto-dismiss to finish (tests advance the clock first).
    func waitForScheduledDismiss() async {
        await dismissTask?.value
    }

    private static func sleeper<C: Clock>(_ clock: C, for duration: Duration) -> @Sendable () async throws -> Void
    where C.Duration == Duration {
        let deadline = clock.now.advanced(by: duration)
        return { try await clock.sleep(until: deadline, tolerance: nil) }
    }

    private func autoDismiss() {
        guard !isHovered else { return }
        dismissTask = nil
        lastDuration = nil
        isPopoverShown = false
    }
}
