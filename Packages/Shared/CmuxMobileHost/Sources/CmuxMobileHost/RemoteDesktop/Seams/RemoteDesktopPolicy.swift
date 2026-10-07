/// Host-side remote desktop rules (c3-rd.md 8).
public struct RemoteDesktopPolicy: Hashable, Sendable {
    public var consent: RemoteDesktopConsentPolicy
    /// Deny when the person at the Mac does not answer in time.
    public var consentTimeout: Duration
    public var clipboard: Bool
    public var vnc: RemoteDesktopVncPolicy
    /// Highest frame rate requested from a target.
    public var maxFPS: Int

    public init(consent: RemoteDesktopConsentPolicy = .ask, consentTimeout: Duration = .seconds(30), clipboard: Bool = true,
                vnc: RemoteDesktopVncPolicy = .allowed(allowLoopback: true), maxFPS: Int = 60) {
        self.consent = consent
        self.consentTimeout = consentTimeout
        self.clipboard = clipboard
        self.vnc = vnc
        self.maxFPS = max(1, maxFPS)
    }
}
