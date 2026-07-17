enum FeedButtonKind: String {
    /// Transparent pill that lights up on hover/selection. Used
    /// for filter bar pills and single-select option pills.
    case ghost
    /// Soft neutral fill (e.g. Manual, disabled Submit).
    case soft
    /// Dark background with white text (Deny).
    case dark
    /// Light background with black text (Allow Once).
    case light
    /// Solid blue (Always Allow, Send feedback, active Submit).
    case primary
    /// Solid green (Auto, checked multi-select option, confirmations).
    case success
    /// Solid orange (warning actions).
    case warning
    /// Solid red (destructive deny).
    case destructive
}
