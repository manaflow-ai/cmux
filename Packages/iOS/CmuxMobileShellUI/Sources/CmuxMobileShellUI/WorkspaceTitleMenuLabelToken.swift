import CmuxMobileShellModel

enum WorkspaceTitleMenuLabelToken: Equatable {
    /// `connectionStatus` drives the title's leading indicator slot — a
    /// spinner while reconnecting, a red dot while disconnected — and
    /// participates in equality so the memoized toolbar label re-renders on
    /// those transitions.
    case standard(
        title: String,
        subtitle: String?,
        connectionStatus: MobileMacConnectionStatus
    )
}
