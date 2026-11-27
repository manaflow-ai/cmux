extension MachinePlanSnapshot {
    /// What the header says about the free plan's access window. Precomputed
    /// against a clock in the view model so no row or meter reads `Date()` in
    /// `body`; `.none` on paid plans and when nothing is on a window.
    public enum FreeAccessBanner: Equatable, Sendable {
        case none
        /// More than a day left; `countdown` reads like "6d 23h".
        case expiresIn(countdown: String)
        /// Under a day left; `countdown` reads like "5h 12m".
        case expiresToday(countdown: String)
        /// The window closed: machines are preserved but locked until upgrade.
        case expired
    }
}
