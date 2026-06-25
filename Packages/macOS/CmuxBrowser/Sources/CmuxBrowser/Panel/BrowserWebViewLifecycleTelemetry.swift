public import Foundation

/// A pure, `Sendable` snapshot of a browser panel's web-view lifecycle state that
/// produces the `browser.*` lifecycle telemetry dictionary.
///
/// The owning `BrowserPanel` reads its live `@MainActor` state into this value and
/// calls ``payload()`` to assemble the `[String: Any]` dict consumed by the control
/// system's "top context" node (bridged to JSON app-side). All inputs are primitive
/// value types, so the type is `Sendable` and the formatting is decoupled from the
/// panel's mutable state. The dictionary keys and the timestamp encoding are stable
/// lifecycle telemetry tokens; do not rename them.
public struct BrowserWebViewLifecycleTelemetry: Sendable {
    /// The raw lifecycle-state token (``BrowserWebViewLifecycleState/rawValue``).
    public let state: String

    /// Whether the panel's web view is currently visible in the UI.
    public let isVisibleInUI: Bool

    /// Whether the panel should render a live web view at all.
    public let shouldRenderWebView: Bool

    /// The discard blockers currently preventing a hidden-view discard; empty means
    /// the view is discard-eligible.
    public let discardBlockers: [String]

    /// When the web view was discarded to reclaim memory, if discarded.
    public let discardedAt: Date?

    /// The reason for the most recent discard, if any.
    public let lastDiscardReason: String?

    /// The reason for the most recent restore, if any.
    public let lastRestoreReason: String?

    /// When the web view was last visible, if ever.
    public let lastVisibleAt: Date?

    /// When the web view was last hidden, if ever.
    public let lastHiddenAt: Date?

    /// When the visibility last changed, if ever.
    public let lastVisibilityChangeAt: Date?

    /// The reason for the most recent visibility change, if any.
    public let lastVisibilityChangeReason: String?

    /// The clock used to compute the hidden duration; defaults to "now".
    public let now: Date

    /// Creates a telemetry snapshot from primitive lifecycle inputs.
    public init(
        state: String,
        isVisibleInUI: Bool,
        shouldRenderWebView: Bool,
        discardBlockers: [String],
        discardedAt: Date?,
        lastDiscardReason: String?,
        lastRestoreReason: String?,
        lastVisibleAt: Date?,
        lastHiddenAt: Date?,
        lastVisibilityChangeAt: Date?,
        lastVisibilityChangeReason: String?,
        now: Date
    ) {
        self.state = state
        self.isVisibleInUI = isVisibleInUI
        self.shouldRenderWebView = shouldRenderWebView
        self.discardBlockers = discardBlockers
        self.discardedAt = discardedAt
        self.lastDiscardReason = lastDiscardReason
        self.lastRestoreReason = lastRestoreReason
        self.lastVisibleAt = lastVisibleAt
        self.lastHiddenAt = lastHiddenAt
        self.lastVisibilityChangeAt = lastVisibilityChangeAt
        self.lastVisibilityChangeReason = lastVisibilityChangeReason
        self.now = now
    }

    /// Assembles the lifecycle telemetry dictionary. `Date?` fields encode as
    /// ISO 8601 strings (or `NSNull`), and `hidden_duration_ms` is non-`nil` only
    /// while the view is hidden.
    public func payload() -> [String: Any] {
        [
            "state": state,
            "visible_in_ui": isVisibleInUI,
            "should_render": shouldRenderWebView,
            "discard_eligible": discardBlockers.isEmpty,
            "discard_blockers": discardBlockers,
            "discarded_at": Self.timestamp(discardedAt),
            "last_discard_reason": lastDiscardReason.map { $0 as Any } ?? NSNull(),
            "last_restore_reason": lastRestoreReason.map { $0 as Any } ?? NSNull(),
            "last_visible_at": Self.timestamp(lastVisibleAt),
            "last_hidden_at": Self.timestamp(lastHiddenAt),
            "last_visibility_change_at": Self.timestamp(lastVisibilityChangeAt),
            "last_visibility_change_reason": lastVisibilityChangeReason.map { $0 as Any } ?? NSNull(),
            "hidden_duration_ms": Self.hiddenDurationMilliseconds(
                hiddenAt: lastHiddenAt,
                visible: isVisibleInUI,
                now: now
            )
        ]
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp(_ date: Date?) -> Any {
        guard let date else { return NSNull() }
        return timestampFormatter.string(from: date)
    }

    private static func hiddenDurationMilliseconds(
        hiddenAt: Date?,
        visible: Bool,
        now: Date
    ) -> Any {
        guard !visible, let hiddenAt else { return NSNull() }
        return max(0, Int((now.timeIntervalSince(hiddenAt) * 1000.0).rounded()))
    }
}
