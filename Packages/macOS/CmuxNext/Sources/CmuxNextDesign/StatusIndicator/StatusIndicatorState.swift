public import CoreGraphics

/// What one status indicator shows (plans/cmux-next/status-indicators.md).
/// Owners (the session host, the workspace store, the browser runtime)
/// report facts; clients turn the strongest one into this value and draw it
/// with `StatusIndicatorLayer`.
public nonisolated enum StatusIndicatorState: Hashable, Sendable {
    /// Nothing to show.
    case idle
    /// Work in progress: `progress` in 0...1 when known (OSC 9;4, `cmux
    /// status set --progress`), else nil (indeterminate).
    case busy(progress: Double?)
    /// Work stopped part way (OSC 9;4 state 4).
    case paused(progress: Double?)
    /// Waiting for the user (an agent asks for approval).
    case waiting
    case error
    /// A finished run, shown until its owner clears it (`status run` badge).
    case success

    /// Indeterminate busy, the common case.
    public static let busy = StatusIndicatorState.busy(progress: nil)

    public var isVisible: Bool { self != .idle }

    /// Busy or paused: the states a loading indicator draws.
    public var isLoading: Bool {
        switch self {
        case .busy, .paused: true
        case .idle, .waiting, .error, .success: false
        }
    }

    /// The known progress, clamped to 0...1; nil when indeterminate or not
    /// loading.
    public var progress: Double? {
        switch self {
        case .busy(let value), .paused(let value):
            guard let value, value.isFinite else { return nil }
            return min(max(value, 0), 1)
        case .idle, .waiting, .error, .success:
            return nil
        }
    }
}

/// How a loading state is drawn (`appearance.statusIndicator.style`).
public nonisolated enum StatusIndicatorStyle: String, Hashable, Sendable, CaseIterable {
    /// The thin rotating arc (default).
    case arc
    /// The macOS spinning progress indicator (NSProgressIndicator), drawn
    /// by AppKit and stepped like the native control.
    case native
    /// A small pulsing dot.
    case dot
    /// No loading indicator; waiting, error and success marks still show.
    case none
}

nonisolated extension StatusIndicatorStyle: TunableChoice {
    public var tunableTitle: String { rawValue }
}

/// `appearance.statusIndicator.*` in cmux.json.
public nonisolated struct StatusIndicatorSettings: Hashable, Sendable {
    public var style: StatusIndicatorStyle = .arc
    /// Share of the host's indicator slot the glyph fills.
    public var scale: CGFloat = 1
    /// Stroke width of the arc and the progress ring, in points.
    public var thickness: CGFloat = 1.5
    /// Loading color; nil takes the theme's secondary text color (derived
    /// from the Ghostty theme, never an accent blue).
    public var color: ThemeRGB?

    public init(style: StatusIndicatorStyle = .arc, scale: CGFloat = 1, thickness: CGFloat = 1.5, color: ThemeRGB? = nil) {
        self.style = style
        self.scale = scale
        self.thickness = thickness
        self.color = color
    }

    public static let scaleRange: ClosedRange<CGFloat> = 0.5...1.5
    public static let thicknessRange: ClosedRange<CGFloat> = 0.5...4
}
