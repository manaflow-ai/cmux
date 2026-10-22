public import AppKit
public import CmuxNextActions
public import CmuxNextBrowserImport

/// What the App supplies to ``CookieImportService``: who asked, the target profile, where to show
/// the permission card, where the cookies go and where the audit record is kept.
public struct CookieImportHost {
    /// Who asked (the agent chat, Home Chief or terminal tab the run's caller names).
    public var requester: @MainActor (ActionInvocation) -> CookieImportRequester
    /// The cmux browser profile the run targets: its id and its name.
    public var target: @MainActor (ActionInvocation) -> (id: String, name: String)
    /// The window for the window card and the done toast, nil when cmux has none.
    public var window: @MainActor () -> NSWindow?
    /// Shows the ask inline where the person talks to the requester (the Home Chief's chat, the
    /// agent's chat tab) and returns true, or returns false when no such chat is on screen; the
    /// service then shows the window card. The host keeps the card up until ``CookieImportAsk/isDismissed``.
    public var presentInline: @MainActor (CookieImportAsk) -> Bool
    /// Reveals a tab as a person's click (`tab.focus`).
    public var reveal: @MainActor (String) -> Void
    /// Opens the Cookie Imports window (`browser.cookieImports`).
    public var showAll: @MainActor () -> Void
    /// Reports the import's work so the CLI waits for it (`ActionRegistry.track`).
    public var track: @MainActor (ActionWork) -> Void
    /// Where the cookies go (the target profile's Chromium cookie jar).
    public var destination: any CookieDestination
    /// The audit ledger: one record per request, whatever its outcome.
    public var ledger: CookieImportLedger
    /// The browsers on this Mac (folder names and Local State only, no cookie file).
    public var sources: @Sendable () async -> [BrowserSource]
    /// The Safe Storage keys of Chromium browsers (the macOS Keychain prompt).
    public var keys: @Sendable () -> any SafeStorageKeyProviding
    /// How long after the card shows Allow starts to work.
    public var armDelay: Duration

    /// Creates the host.
    ///
    /// - Parameters:
    ///   - requester: Who asked, from the run's caller fields.
    ///   - target: The target cmux browser profile's id and name.
    ///   - window: The window for the window card and toasts.
    ///   - presentInline: Shows the ask in the requester's chat; false when none is on screen.
    ///   - reveal: Reveals a tab by id.
    ///   - showAll: Opens the Cookie Imports window.
    ///   - track: Reports the import task to a capturing caller.
    ///   - destination: Where the cookies go.
    ///   - ledger: The audit ledger.
    ///   - sources: Finds the browsers on this Mac.
    ///   - keys: Makes the Safe Storage key reader of one import (one Keychain read each).
    ///   - armDelay: The card's arming beat (``CookieImportAsk/defaultArmDelay``; tests pass zero).
    public init(requester: @escaping @MainActor (ActionInvocation) -> CookieImportRequester,
                target: @escaping @MainActor (ActionInvocation) -> (id: String, name: String),
                window: @escaping @MainActor () -> NSWindow?,
                presentInline: @escaping @MainActor (CookieImportAsk) -> Bool = { _ in false },
                reveal: @escaping @MainActor (String) -> Void,
                showAll: @escaping @MainActor () -> Void = {},
                track: @escaping @MainActor (ActionWork) -> Void, destination: any CookieDestination,
                ledger: CookieImportLedger = CookieImportLedger(file: CookieImportLedger.defaultFile),
                sources: @escaping @Sendable () async -> [BrowserSource] = CookieImportHost.liveSources,
                keys: @escaping @Sendable () -> any SafeStorageKeyProviding = { OneReadSafeStorage(SafeStorageKeys().live()) },
                armDelay: Duration = CookieImportAsk.defaultArmDelay) {
        self.requester = requester
        self.target = target
        self.window = window
        self.presentInline = presentInline
        self.reveal = reveal
        self.showAll = showAll
        self.track = track
        self.destination = destination
        self.ledger = ledger
        self.sources = sources
        self.keys = keys
        self.armDelay = armDelay
    }

    /// The browsers this Mac has, found off the main thread from folder names only.
    public static let liveSources: @Sendable () async -> [BrowserSource] = {
        await Task.detached {
            let environment = ImportEnvironment.live { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
            return BrowserSourceDetector(environment: environment).detect()
        }.value
    }
}
