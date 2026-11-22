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
    /// An agent works (an ACP turn runs, a hook reports working, a program
    /// reports OSC 7501 `working`): drawn unlike page or command loading
    /// (WORKING-AND-LOADING-INDICATORS). `progress` in 0...1 when the
    /// program reports one.
    case working(progress: Double?)
    /// Waiting for the user (an agent asks for approval). `kind` says what
    /// for when the reporter names it (OSC 7501 `kind`); nil is plain blocked.
    case waiting(kind: StatusBlockedKind?)
    case error
    /// A finished run, shown until its owner clears it (`status run` badge).
    case success

    /// Indeterminate busy, the common case.
    public static let busy = StatusIndicatorState.busy(progress: nil)
    /// An agent working with no known progress, the common case.
    public static let working = StatusIndicatorState.working(progress: nil)
    /// Waiting for the user with no known reason, the common case.
    public static let waiting = StatusIndicatorState.waiting(kind: nil)

    /// What a waiting state waits for; nil for every other state.
    public var blockedKind: StatusBlockedKind? {
        if case .waiting(let kind) = self { return kind }
        return nil
    }

    public var isVisible: Bool { self != .idle }

    /// Busy or paused: the states a loading indicator draws.
    public var isLoading: Bool {
        switch self {
        case .busy, .paused: true
        case .idle, .working, .waiting, .error, .success: false
        }
    }

    /// An agent works (`working`).
    public var isWorking: Bool {
        if case .working = self { return true }
        return false
    }

    /// The states a tab draws in its icon slot in place of the icon:
    /// loading and agent work. Waiting, error and done stay on the badge.
    public var replacesTabIcon: Bool { isLoading || isWorking }

    /// The known progress, clamped to 0...1; nil when indeterminate or not
    /// loading.
    public var progress: Double? {
        switch self {
        case .busy(let value), .paused(let value), .working(let value):
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
    /// The terminal's braille spinner (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏), drawn in the terminal
    /// font, so working states read like the CLI tools running in it.
    case braille
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
    /// Sources whose style hint (`cmux status set --style`) wins over
    /// `style` (`appearance.statusIndicator.honorStatusStyle`: true, false,
    /// or a list of sources). All by default.
    public var honoredStyleSources: Set<StatusReport.Source> = Set(StatusReport.Source.allCases)
    /// A working agent draws its dots in its tab's icon slot
    /// (`appearance.statusIndicator.showAgentWorkingOnTabs`). The workspace
    /// row's working element has its own switch (the row-content settings).
    public var showsAgentWorkingOnTabs = true
    /// A loading page draws its spinner in its browser tab's icon slot
    /// (`appearance.statusIndicator.showPageLoading`); off, the tab keeps its favicon.
    public var showsPageLoading = true

    public init(style: StatusIndicatorStyle = .arc, scale: CGFloat = 1, thickness: CGFloat = 1.5, color: ThemeRGB? = nil,
                honoredStyleSources: Set<StatusReport.Source> = Set(StatusReport.Source.allCases)) {
        self.style = style
        self.scale = scale
        self.thickness = thickness
        self.color = color
        self.honoredStyleSources = honoredStyleSources
    }

    public static let scaleRange: ClosedRange<CGFloat> = 0.5...1.5
    public static let thicknessRange: ClosedRange<CGFloat> = 0.5...4
}
