/// Asks the person at the Mac (c3-rd.md 8): a floating panel at the top
/// center of the active screen with Allow and Deny and no default button.
/// Returns false on Deny. The session cancels the task on its timeout or
/// when the phone goes away; implementations dismiss the panel then.
public protocol RemoteDesktopConsent: Sendable {
    func request(_ request: RemoteDesktopConsentRequest) async -> Bool
}
