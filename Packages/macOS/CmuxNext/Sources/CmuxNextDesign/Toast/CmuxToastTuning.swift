public import CoreGraphics
public import CmuxNextDesignTokens

/// The toast look and timing as of now: every ``CmuxToastTunables`` knob, read once from a tunable
/// store. The center times toasts by it (``shownDuration(of:)``) and the host builds each toast view
/// with it, so a Debug Settings change shows on the next toast.
///
/// ```swift
/// let tuning = CmuxToastTuning()            // the code defaults
/// let live = CmuxToastTuning(store: .shared) // Debug Settings' overrides, else the defaults
/// live.shownDuration(of: toast)              // twice the asked time, at least 6 s
/// ```
public nonisolated struct CmuxToastTuning: Equatable, Sendable {
    public var durationScale: Double
    public var minimumSeconds: Double
    public var glass: CmuxToastGlass
    public var horizontalPadding: CGFloat
    public var trailingPadding: CGFloat
    public var verticalPadding: CGFloat
    public var buttonSpacing: CGFloat
    public var messageWidth: CGFloat
    public var rise: CGFloat

    /// The code defaults (no override).
    public init() {
        self.init(read: { $0.defaultValue }, glass: CmuxToastTunables.glass.defaultValue)
    }

    /// The tunables' values in `store`: its overrides, else the defaults. Reading registers an
    /// Observation dependency on each knob.
    public init(store: TunableStore) {
        self.init(read: { $0.value(in: store) }, glass: CmuxToastTunables.glass.value(in: store))
    }

    private init(read: (Tunable<Double>) -> Double, glass: CmuxToastGlass) {
        durationScale = read(CmuxToastTunables.durationScale)
        minimumSeconds = read(CmuxToastTunables.minimumSeconds)
        self.glass = glass
        horizontalPadding = CGFloat(read(CmuxToastTunables.horizontalPadding))
        trailingPadding = CGFloat(read(CmuxToastTunables.trailingPadding))
        verticalPadding = CGFloat(read(CmuxToastTunables.verticalPadding))
        buttonSpacing = CGFloat(read(CmuxToastTunables.buttonSpacing))
        messageWidth = CGFloat(read(CmuxToastTunables.messageWidth))
        rise = CGFloat(read(CmuxToastTunables.rise))
    }

    /// How long `toast` shows: its asked time times ``durationScale``, never under ``minimumSeconds``.
    /// A toast that waits for an answer (``CmuxToast/untilClosed``) or keeps its time
    /// (``CmuxToast/keepsDuration``) shows for exactly its asked time.
    public func shownDuration(of toast: CmuxToast) -> Duration {
        guard toast.duration != CmuxToast.untilClosed, !toast.keepsDuration else { return toast.duration }
        return max(toast.duration * durationScale, .seconds(minimumSeconds))
    }
}
