import Foundation

/// The provider endpoint, from the daemon. Nil until the daemon offers it;
/// the provider then stays idle until `credentialsChanged()`.
@MainActor
public protocol ProviderCredentialsSource: AnyObject {
    func providerCredentials() async -> ProviderCredentials?
}

/// Every browser tab the app renders. Read inside Observation tracking:
/// a change to any observable state the getter reads makes the provider
/// diff the list again (`tab.announced`, `tab.navigated`, `tab.gone`).
/// State that is not observable is pushed with `refreshTabs()`.
@MainActor
public protocol ProviderTabSource: AnyObject {
    var providerTabs: [ProviderTab] { get }
    /// Whether the source announces tab `targetID`, from that tab's own facts now. A source whose list follows its
    /// model later (the app's: one main-actor turn) answers before the list holds the tab; the provider asks it for
    /// a popup whose announce has not left yet. Called outside Observation tracking.
    func isDrivable(_ targetID: String) -> Bool
}

extension ProviderTabSource {
    /// A source whose list is exact: the tab is in it.
    public func isDrivable(_ targetID: String) -> Bool { providerTabs.contains { $0.targetID == targetID } }
}

/// The extension access of a CEF tab, read inside Observation tracking
/// (the profile's extension store and the page URL are observable).
@MainActor
public protocol ProviderAccessSource: AnyObject {
    func access(forTab targetID: String) -> ProviderTabAccess
}
