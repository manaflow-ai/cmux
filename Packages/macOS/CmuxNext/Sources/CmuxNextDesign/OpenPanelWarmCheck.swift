/// What a made-ahead panel's warm-up finds when its timer fires (``MadeAheadPanelStore``, from ``OpenPanelWarmGate``).
enum OpenPanelWarmCheck: Sendable, Equatable {
    /// This process cannot make a working panel now (it never ran the app's event loop, or this account is not the
    /// console user): this warm-up ends without making one; a later `warmWhenIdle()` may start another. `reason` goes
    /// in the store's one log notice, so a bench log shows the made-ahead path was off.
    case never(reason: String)
    /// The person is busy (recent input, a tracking loop): check again a second later, within the bound.
    case busy
    /// Make the panel now.
    case ready
}
