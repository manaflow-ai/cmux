/// Whether a blocked or bypassed insecure-HTTP navigation targets the current
/// browser tab or a freshly opened one.
///
/// The insecure-HTTP allowlist policy and the new-tab opener both branch on this
/// to decide which surface receives a plain-HTTP navigation after a block or a
/// one-shot bypass.
public enum BrowserInsecureHTTPNavigationIntent: Sendable {
    /// The navigation replaces the content of the originating tab.
    case currentTab

    /// The navigation opens in a newly created sibling tab.
    case newTab
}
