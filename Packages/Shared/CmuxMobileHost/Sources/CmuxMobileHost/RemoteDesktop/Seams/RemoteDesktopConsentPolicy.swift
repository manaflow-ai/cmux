/// Whether the Mac asks before each session. A Mac setting, never a phone param.
public enum RemoteDesktopConsentPolicy: Hashable, Sendable {
    /// Ask for every session, and again before control.
    case ask
    /// The owner opted out of the panel for their own devices; the indicator still shows.
    case indicatorOnly
}
