public import Foundation

/// Pure `#if DEBUG` payload producers for the jump-to-unread / multi-window
/// notification-open routing trace.
///
/// The notification-open routing trio (`openNotification`,
/// `openNotificationInContext`, `openNotificationFallback`) records, at each
/// decision branch, either a `[String: String]` capture written verbatim to the
/// env-gated jump-to-unread test file, or a multi-window open-failure reason
/// string. Those literals are pure DEBUG data with no AppKit, no state, and no
/// behavior: this value type owns them so the producing branches read as one
/// named factory each instead of an inline dictionary literal.
///
/// `fields` carries the jump-to-unread capture written through the app-side
/// `writeJumpUnreadTestData(_:)`; the `*Reason` members build the strings passed
/// to the app-side `recordMultiWindowNotificationOpenFailureIfNeeded(...)`. Both
/// app-side sinks keep their signatures; only the literals they are handed now
/// come from here, byte-identical to the inlined originals.
public struct NotificationOpenRoutingTrace: Sendable, Equatable {
    /// The jump-to-unread capture fields, written verbatim to the env-gated
    /// test file via the app-side `writeJumpUnreadTestData(_:)`.
    public let fields: [String: String]

    /// Creates a trace from its raw capture fields.
    public init(fields: [String: String]) {
        self.fields = fields
    }

    /// `openNotification` entry record: the call fired with its tab/surface ids.
    public static func openCalled(tabId: UUID, surfaceId: UUID?) -> NotificationOpenRoutingTrace {
        NotificationOpenRoutingTrace(fields: [
            "jumpUnreadOpenCalled": "1",
            "jumpUnreadOpenTabId": tabId.uuidString,
            "jumpUnreadOpenSurfaceId": surfaceId?.uuidString ?? "",
        ])
    }

    /// No owning window context was found; routing fell back to the active window.
    public static let contextMissingUsedFallback = NotificationOpenRoutingTrace(fields: [
        "jumpUnreadOpenContextFound": "0",
        "jumpUnreadOpenUsedFallback": "1",
    ])

    /// The final open result (`"1"` on success, `"0"` on failure).
    public static func openResult(_ ok: Bool) -> NotificationOpenRoutingTrace {
        NotificationOpenRoutingTrace(fields: ["jumpUnreadOpenResult": ok ? "1" : "0"])
    }

    /// The owning window context was found; no fallback was used.
    public static let contextFoundNoFallback = NotificationOpenRoutingTrace(fields: [
        "jumpUnreadOpenContextFound": "1",
        "jumpUnreadOpenUsedFallback": "0",
    ])

    /// Focus succeeded in the resolved registered window context.
    public static let openedInContext = NotificationOpenRoutingTrace(fields: [
        "jumpUnreadOpenInContext": "1",
        "jumpUnreadOpenResult": "1",
    ])

    /// A fallback-path failure before focus was attempted, tagged with `stage`
    /// (`"missing_tabManager"`, `"tab_not_in_active_manager"`, `"missing_window"`).
    public static func fallbackFailed(_ stage: String) -> NotificationOpenRoutingTrace {
        NotificationOpenRoutingTrace(fields: ["jumpUnreadFallbackFail": stage])
    }

    /// The fallback path reached focus but `focusTabFromNotification` failed.
    public static let fallbackFocusFailed = NotificationOpenRoutingTrace(fields: [
        "jumpUnreadFallbackFail": "focus_failed",
        "jumpUnreadOpenResult": "0",
    ])

    /// Focus succeeded on the active-window fallback path.
    public static let openedInFallback = NotificationOpenRoutingTrace(fields: [
        "jumpUnreadOpenInFallback": "1",
        "jumpUnreadOpenResult": "1",
    ])

    /// Multi-window open-failure reason: no registered window owns the tab.
    public static let missingContextReason = "missing_context"

    /// Multi-window open-failure reason: the owning context resolved but its
    /// `NSWindow` could not be found, carrying the expected window identifier.
    public static func missingWindowReason(expectedIdentifier: String) -> String {
        "missing_window expectedIdentifier=\(expectedIdentifier)"
    }

    /// Multi-window open-failure reason: `focusTabFromNotification` returned false.
    public static let focusFailedReason = "focus_failed"
}
