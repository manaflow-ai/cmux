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
    /// and navigations, which replace the page anyway.
    private static let independentOfPage: Set<String> = [
        "tabs.close", "tab.keep", "tab.navigate", "tab.reload", "tab.history",
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
    /// - Parameters:
    ///   - condition: The tab's current condition; read again after each step.
    ///   - wake: Starts the restore of a hibernated tab (a no-op while one runs).
    ///   - waitUntilLoaded: Returns once the restored page has loaded, or
    ///     when it can no longer load (the restore failed). It keeps running
    ///     in the background when ``timeout`` passes first.
    public func prepare(
        method: String,
        tab: BrowserReplTabLabel,
        condition: () -> BrowserReplTabCondition,
        wake: () -> Void,
        waitUntilLoaded: @escaping @MainActor () async -> Void
    ) async throws {
        var current = condition()
        if current.isCrashed {
            if Self.answeredWhenCrashed.contains(method) { return }
            throw Self.crashedError(method: method, tab: tab)
        }
        guard current.isHibernated, Self.wakesHibernatedTab(method) else { return }
        wake()
        current = condition()
        if current.isHibernated, !current.isWaking {
            throw Self.notRestoredError(method: method, tab: tab, stopped: current.restoreStoppedByUser)
        }
        let loaded = await race(waitUntilLoaded)
        current = condition()
        if current.isCrashed { throw Self.crashedError(method: method, tab: tab) }
        guard current.isHibernated else { return }
        if loaded || !current.isWaking {
            throw Self.notRestoredError(method: method, tab: tab, stopped: current.restoreStoppedByUser)
        }
        throw BrowserReplDriverError(
            code: "timeout",
            message: "\(method): \(tab) was hibernated (cmux unloaded it to save memory while it was hidden) and did not load again within \(Self.seconds(timeout)) s, so the call did not run. It is still loading: retry the call, or call page.reload()"
        )
    }

    /// Whether `body` finished before the deadline.
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
        let finished = await race.value()
        deadline.cancel()
        if !finished { work.cancel() }
        return finished
    }

    private static func seconds(_ duration: Duration) -> Int {
        Int(duration.components.seconds)
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
