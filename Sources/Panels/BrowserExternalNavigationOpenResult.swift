/// Describes the outcome of applying a configured external-navigation rule.
enum BrowserExternalNavigationOpenResult: Equatable {
    /// No configured rule selected this URL.
    case notConfigured
    /// A configured URL was accepted by the system opener.
    case opened
    /// A configured URL could not be handed to the system opener.
    case failed
}
