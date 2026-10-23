/// What a made-ahead panel's warm-up finds when its timer fires (``MadeAheadPanelStore``).
enum OpenPanelWarmCheck: Sendable {
    /// This process cannot make a working panel now (it never ran the app's event loop): this warm-up ends; a later
    /// `warmWhenIdle()` may start another.
    case never
    /// The person is busy (recent input, a tracking loop): check again a second later, within the bound.
    case busy
    /// Make the panel now.
    case ready
}
