public import Foundation

/// The state of a tab's web content as the REPL reports it (`tabs.list`,
/// `tab.info`).
public enum BrowserReplTabState: String, Sendable {
    /// The page is loaded and answers driver calls.
    case live
    /// cmux unloaded the hidden page to save memory; the tab keeps its URL
    /// and history, and the next driver call loads it again.
    case hibernated
    /// A hibernated page is loading again.
    case waking
    /// The tab's web content process ended; a reload or navigation starts a
    /// new one.
    case crashed
}

/// What a driver knows about a tab's web content before a call.
public struct BrowserReplTabCondition: Equatable, Sendable {
    /// cmux unloaded the page (`BrowserHiddenWebViewDiscardManager`).
    public var isHibernated: Bool
    /// The unloaded page's restore navigation is running.
    public var isWaking: Bool
    /// The web content process ended and the tab waits for a reload.
    public var isCrashed: Bool
    /// The user pressed Stop on the tab, so cmux does not load it on its own.
    public var restoreStoppedByUser: Bool

    public init(
        isHibernated: Bool = false,
        isWaking: Bool = false,
        isCrashed: Bool = false,
        restoreStoppedByUser: Bool = false
    ) {
        self.isHibernated = isHibernated
        self.isWaking = isWaking
        self.isCrashed = isCrashed
        self.restoreStoppedByUser = restoreStoppedByUser
    }

    public var state: BrowserReplTabState {
        if isCrashed { return .crashed }
        guard isHibernated else { return .live }
        return isWaking ? .waking : .hibernated
    }
}

/// Names a tab in driver errors: its id, which `tabs.list()` shows, with its
/// title and URL so the agent can tell which page is meant.
public struct BrowserReplTabLabel: Sendable, CustomStringConvertible {
    public let id: String
    public let title: String
    public let url: String

    public init(id: String, title: String, url: String) {
        self.id = id
        self.title = title
        self.url = url
    }

    public var description: String {
        let details = [title.isEmpty ? nil : "\"\(title)\"", url.isEmpty ? nil : url].compactMap { $0 }
        return details.isEmpty ? "tab \(id)" : "tab \(id) (\(details.joined(separator: ", ")))"
    }
}

/// What ``BrowserReplTabWaker/prepare(method:tab:condition:wake:recoverCrash:waitUntilLoaded:)`` did.
public enum BrowserReplTabPreparation: Equatable, Sendable {
    /// The tab is ready; run the call.
    case ready
    /// The call was `tab.reload` on a crashed or hibernated tab: bringing the
    /// page back was the reload, and its page has loaded.
    case reloaded
}

/// Brings a tab's web content back before a driver call that needs it.
///
/// cmux unloads hidden browser tabs to save memory (hibernation). A tab a
/// session drives is not unloaded while the session is attached, but a
/// user's tab, or a tab a finished run kept, can be hibernated before a
/// session reaches it. A call that needs the page wakes it: the driver
/// starts the restore and the call waits, at most ``timeout``, until the
/// page has loaded again. A tab whose web content process crashed is not
/// reloaded behind the agent's back; calls that need the page fail with a
/// `crashed` error that says how to recover.
@MainActor
public struct BrowserReplTabWaker {
    /// How long a call waits for a hibernated tab to load again.
    public static let defaultTimeout: Duration = .seconds(30)

    private let sleeper: any BrowserReplSleeping
    private let timeout: Duration

    public init(sleeper: any BrowserReplSleeping, timeout: Duration = Self.defaultTimeout) {
        self.sleeper = sleeper
        self.timeout = timeout
    }

    /// Methods that never use the tab's current page: closing or keeping it,
    /// and navigations away, which replace the page anyway.
    private static let independentOfPage: Set<String> = [
        "tabs.close", "tab.keep", "tab.navigate", "tab.history",
        "tab.handleEvents", "tabs.activate", "tab.bringToFront",
    ]

    /// Methods a crashed tab still answers: the navigations that start a new
    /// web content process, and calls that read or show the tab without its page.
    private static let answeredWhenCrashed: Set<String> = [
        "tabs.close", "tab.keep", "tab.navigate", "tab.reload", "tab.history",
        "tab.info", "tabs.activate", "tab.bringToFront", "tab.handleEvents",
    ]

    /// Whether `method` wakes a hibernated tab before it runs.
    public static func wakesHibernatedTab(_ method: String) -> Bool {
        !independentOfPage.contains(method)
    }

    /// Makes the tab ready for `method`, or throws why it cannot be.
    ///
    /// `tab.reload` on a crashed or hibernated tab is answered here: loading
    /// the page into a new or restored web view is the reload, and a reload
    /// of the old web view would be superseded by it.
    ///
    /// - Parameters:
    ///   - condition: The tab's current condition; read again after each step.
    ///   - wake: Starts the restore of a hibernated tab (a no-op while one runs).
    ///   - recoverCrash: Starts loading a crashed tab's page in a new web
    ///     content process (only for `tab.reload`).
    ///   - waitUntilLoaded: Returns once the restored page has loaded, or
    ///     when it can no longer load (the restore failed). It keeps running
    ///     in the background when ``timeout`` passes first.
    @discardableResult
    public func prepare(
        method: String,
        tab: BrowserReplTabLabel,
        condition: () -> BrowserReplTabCondition,
        wake: () -> Void,
        recoverCrash: () -> Void,
        waitUntilLoaded: @escaping @MainActor () async -> Void
    ) async throws -> BrowserReplTabPreparation {
        var current = condition()
        let isReload = method == "tab.reload"
        if current.isCrashed {
            guard isReload else {
                if Self.answeredWhenCrashed.contains(method) { return .ready }
                throw Self.crashedError(method: method, tab: tab)
            }
            recoverCrash()
            current = condition()
            if current.isCrashed { throw Self.crashedError(method: method, tab: tab) }
            if !current.isHibernated {
                // A new web content process loads the page.
                let loaded = await race(waitUntilLoaded)
                if condition().isCrashed { throw Self.crashedError(method: method, tab: tab) }
                guard loaded else { throw Self.reloadTimeoutError(tab: tab, timeout: timeout) }
                return .reloaded
            }
        } else {
            guard current.isHibernated, Self.wakesHibernatedTab(method) else { return .ready }
        }
        wake()
        current = condition()
        if current.isHibernated, !current.isWaking {
            throw Self.notRestoredError(method: method, tab: tab, stopped: current.restoreStoppedByUser)
        }
        let loaded = await race(waitUntilLoaded)
        current = condition()
        if current.isCrashed { throw Self.crashedError(method: method, tab: tab) }
        guard current.isHibernated else { return isReload ? .reloaded : .ready }
        if loaded || !current.isWaking {
            throw Self.notRestoredError(method: method, tab: tab, stopped: current.restoreStoppedByUser)
        }
        throw BrowserReplDriverError(
            code: "timeout",
            message: "\(method): \(tab) was hibernated (cmux unloaded it to save memory while it was hidden) and did not load again within \(Self.seconds(timeout)) s, so the call did not run. It is still loading: retry the call, or call page.reload()"
        )
    }

    /// Whether `body` finished before the deadline. A cancelled call stops
    /// waiting at once.
    private func race(_ body: @escaping @MainActor () async -> Void) async -> Bool {
        let race = BrowserReplWakeRace()
        let work = Task { @MainActor in
            await body()
            race.finish(true)
        }
        let sleeper = self.sleeper
        let timeout = self.timeout
        let deadline = Task { @MainActor in
            do {
                try await sleeper.sleep(for: timeout)
            } catch {
                return
            }
            race.finish(false)
        }
        let finished = await withTaskCancellationHandler {
            await race.value()
        } onCancel: {
            Task { @MainActor in race.finish(false) }
        }
        deadline.cancel()
        if !finished { work.cancel() }
        return finished
    }

    /// Waits until the tab's current web view commits a document, following
    /// a web view that replaces it meanwhile (a crash recovery).
    ///
    /// - Parameters:
    ///   - instance: The tab's current web view instance, or `nil` when it
    ///     has none.
    ///   - waitForCommit: `BrowserAutomationDocumentReadiness.waitForCommit`.
    /// - Returns: Whether a commit arrived. A wait answered `superseded`
    ///   while the instance stayed the same (the readiness was invalidated by
    ///   a close or crash, and answers at once) ends with `false`, so the
    ///   loop never spins on the main actor.
    public static func waitForPageCommit(
        instance: () -> UUID?,
        waitForCommit: (UUID) async -> BrowserAutomationDocumentReadinessOutcome
    ) async -> Bool {
        while !Task.isCancelled, let waited = instance() {
            switch await waitForCommit(waited) {
            case .committed:
                return true
            case .cancelled:
                return false
            case .superseded:
                guard let next = instance(), next != waited else { return false }
                await Task.yield()
            }
        }
        return false
    }

    private static func seconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
    }

    static func reloadTimeoutError(tab: BrowserReplTabLabel, timeout: Duration) -> BrowserReplDriverError {
        BrowserReplDriverError(
            code: "timeout",
            message: "tab.reload: \(tab) crashed and did not load again within \(seconds(timeout)) s; it is still loading: retry, or call page.reload() again"
        )
    }

    static func crashedError(method: String, tab: BrowserReplTabLabel) -> BrowserReplDriverError {
        BrowserReplDriverError(
            code: "crashed",
            message: "\(method): \(tab) crashed: its web content process ended (a WebKit crash, or macOS reclaimed its memory). Call page.reload() or page.goto(url) to load it again; until then only navigation, tab.info and page.close() work on it"
        )
    }

    static func notRestoredError(method: String, tab: BrowserReplTabLabel, stopped: Bool) -> BrowserReplDriverError {
        let why = stopped
            ? "the user stopped it from loading, so cmux does not load it again on its own"
            : "loading it again did not finish with a page"
        return BrowserReplDriverError(
            code: "hibernated",
            message: "\(method): \(tab) is hibernated (cmux unloaded it to save memory while it was hidden) and \(why). Call page.reload() to load it, then retry"
        )
    }
}

/// First result wins for ``BrowserReplTabWaker``'s bounded wait.
@MainActor
private final class BrowserReplWakeRace {
    private var result: Bool?
    private var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ value: Bool) {
        guard result == nil else { return }
        result = value
        continuation?.resume(returning: value)
        continuation = nil
    }

    func value() async -> Bool {
        if let result { return result }
        return await withCheckedContinuation { continuation = $0 }
    }
}
