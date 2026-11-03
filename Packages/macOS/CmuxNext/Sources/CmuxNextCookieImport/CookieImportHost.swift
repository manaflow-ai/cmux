public import AppKit
public import CmuxNextActions
public import CmuxNextBrowserImport

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
    /// SECURITY: whether a key or mouse event is the person's own input from the HID system (the app's
    /// `PersonInputCheck`): only such a click on the consent panel's Allow allows. The default takes none.
    public var isPersonEvent: @MainActor (NSEvent) -> Bool
    /// The input event being dispatched now, nil between dispatches (the app's `InputDispatchContext`, never
    /// `NSApp.currentEvent`, which keeps the last event after its dispatch ends). The default has none.
    public var dispatchingEvent: @MainActor () -> NSEvent?

    /// Creates the host.
    ///
    /// - Parameters:
    ///   - requester: Who asked, from the run's caller fields.
    ///   - target: The target cmux browser profile's id and name.
    ///   - window: The window to ask in.
    ///   - reveal: Reveals a tab by id.
    ///   - track: Reports the import task to a capturing caller.
    ///   - destination: Where the cookies go.
    ///   - isPersonEvent: Whether an event is the person's own input; the default takes none, so nothing allows.
    ///   - dispatchingEvent: The input event being dispatched now; the default has none, so every run asks.
    public init(requester: @escaping @MainActor (ActionInvocation) -> CookieImportRequester,
                target: @escaping @MainActor (ActionInvocation) -> (id: String, name: String),
                window: @escaping @MainActor () -> NSWindow?, reveal: @escaping @MainActor (String) -> Void,
                track: @escaping @MainActor (ActionWork) -> Void, destination: any CookieDestination,
                isPersonEvent: @escaping @MainActor (NSEvent) -> Bool = { _ in false },
                dispatchingEvent: @escaping @MainActor () -> NSEvent? = { nil }) {
        self.requester = requester
        self.target = target
        self.window = window
        self.reveal = reveal
        self.track = track
        self.destination = destination
        self.isPersonEvent = isPersonEvent
        self.dispatchingEvent = dispatchingEvent
    }
}
