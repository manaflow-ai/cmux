/// Why ``VerificationOfferPolicy`` gave an email no offer on a page. One
/// case per rule of DESIGN.md "Matching", so a test names the rule it proves.
public nonisolated enum VerificationOfferRejection: Error, Sendable, Hashable {
    /// The setting is off (rule 1).
    case featureOff
    /// An agent drives the tab (rule 2).
    case agentDrivenTab
    /// The page is not https (rule 3).
    case insecurePage
    /// The page's host has no registrable domain (an IP, a public suffix).
    case pageHasNoSite
    /// The From address has no registrable domain (rule 4).
    case senderHasNoSite
    /// The sender and the page are different sites (rule 4).
    case differentSite
    /// The origin-bound line names another host than the page's (rule 4).
    case originBoundToAnotherHost
    /// The source says the sender failed DKIM/DMARC.
    case senderFailedAuthentication
    /// The email arrived more than the lookback before the page asked (rule 5).
    case receivedBeforePageAsked
    /// The email arrived more than the window after the page asked (rule 5).
    case receivedAfterWindow
    /// The email is older than the window now (rule 5).
    case expired
    /// No code and no same-site verification link (rules 6, 7).
    case nothingToOffer
    /// Two different codes, or two different verification links (rule 6).
    case ambiguous
}
