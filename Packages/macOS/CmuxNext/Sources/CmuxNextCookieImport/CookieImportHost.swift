public import AppKit
public import CmuxNextActions
public import CmuxNextBrowserImport
public import CmuxNextWakeups

/// What the App supplies to ``CookieImportService``: who asked, the target
/// profile, the window to ask in, and where the cookies go.
public struct CookieImportHost {
    /// Who asked (the agent chat or terminal tab the run's caller names).
    public var requester: @MainActor (ActionInvocation) -> CookieImportRequester
    /// The cmux browser profile the run targets: its id and its name.
    public var target: @MainActor (ActionInvocation) -> (id: String, name: String)
    /// The window to show the consent panel and the done toast in, nil when cmux has none.
    public var window: @MainActor () -> NSWindow?
    /// Reveals a tab as a person's click (`tab.focus`).
    public var reveal: @MainActor (String) -> Void
    /// Reports the import's work so the CLI waits for it (`ActionRegistry.track`).
    public var track: @MainActor (ActionWork) -> Void
    /// Where the cookies go (the target profile's Chromium cookie jar).
    public var destination: any CookieDestination
    /// The app's one deadline placer: the consent panel's limit, and through its `work` the run's main-thread steps.
    public var deadlines: MainDeadlineScheduler

    /// Creates the host.
    ///
    /// - Parameters:
    ///   - requester: Who asked, from the run's caller fields.
    ///   - target: The target cmux browser profile's id and name.
    ///   - window: The window to ask in.
    ///   - reveal: Reveals a tab by id.
    ///   - track: Reports the import task to a capturing caller.
    ///   - destination: Where the cookies go.
    ///   - deadlines: The app's one deadline placer.
    public init(requester: @escaping @MainActor (ActionInvocation) -> CookieImportRequester,
                target: @escaping @MainActor (ActionInvocation) -> (id: String, name: String),
                window: @escaping @MainActor () -> NSWindow?, reveal: @escaping @MainActor (String) -> Void,
                track: @escaping @MainActor (ActionWork) -> Void, destination: any CookieDestination,
                deadlines: MainDeadlineScheduler) {
        self.requester = requester
        self.target = target
        self.window = window
        self.reveal = reveal
        self.track = track
        self.destination = destination
        self.deadlines = deadlines
    }
}
