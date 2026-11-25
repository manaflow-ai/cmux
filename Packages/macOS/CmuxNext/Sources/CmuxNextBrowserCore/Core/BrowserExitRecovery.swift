public import CmuxNextCompat

/// Whether a tab whose content process ended loads its page again by itself: once, and only when
/// the system ended the process for memory.
///
/// A content process that ran out of memory, or that was killed or crashed while the Mac was short
/// of memory, was not ended by its page: what the page held is gone either way, and the crash page
/// would only cost a click. So such a tab reloads by itself, once, the next time it is shown (at
/// once when it is on screen), and hidden tabs never reload together while memory is short. A second
/// such end within ``window`` of the last automatic reload shows the crash page and waits for the
/// person's Reload, so a page that keeps dying never loops. Any other end (a crash with memory to
/// spare, a kill from outside) always waits for the person's Reload, as before.
///
/// Each engine's tab keeps one value and feeds it every end and every show:
///
/// ```swift
/// var recovery = BrowserExitRecovery()
/// _ = recovery.processEnded(exit, pressure: .critical, now: .now)  // true: a reload is owed
/// if recovery.takeReload(now: .now) { reload() }                    // when the tab is shown
/// ```
public nonisolated struct BrowserExitRecovery: Sendable {
    /// How long after an automatic reload another memory end waits for the person instead.
    public var window: Duration
    /// The tab owes one automatic reload, taken when it is next shown.
    public private(set) var isReloadOwed = false
    private var lastReload: ContinuousClock.Instant?

    /// - Parameter window: The quiet period between two automatic reloads of one tab; ten minutes
    ///   by default, longer than a page takes to load and use memory again under steady pressure.
    public init(window: Duration = .seconds(600)) {
        self.window = window
    }

    /// Whether `exit` was the system ending the process for memory: out of memory, or killed or
    /// crashed while memory `pressure` was warning or critical.
    ///
    /// - Parameters:
    ///   - exit: How the content process ended.
    ///   - pressure: The system's memory pressure when it ended.
    /// - Returns: True for a memory end.
    public static func isMemoryEnd(_ exit: BrowserProcessExit, pressure: MemoryPressureLevel) -> Bool {
        switch exit.reason {
        case .outOfMemory: true
        case .killed, .crashed, .abnormal: pressure != .normal
        case .launchFailed, .integrityFailure: false
        }
    }

    /// The tab's content process ended with `exit` under `pressure`.
    ///
    /// - Returns: True when the tab now owes one automatic reload (``takeReload(now:)``).
    @discardableResult
    public mutating func processEnded(_ exit: BrowserProcessExit, pressure: MemoryPressureLevel,
                                      now: ContinuousClock.Instant) -> Bool {
        let recent = lastReload.map { now - $0 < window } ?? false
        isReloadOwed = Self.isMemoryEnd(exit, pressure: pressure) && !recent
        return isReloadOwed
    }

    /// The tab is shown (or was on screen when it ended): true once when it should reload now.
    public mutating func takeReload(now: ContinuousClock.Instant) -> Bool {
        guard isReloadOwed else { return false }
        isReloadOwed = false
        lastReload = now
        return true
    }

    /// The person reloaded or navigated the tab: nothing is owed any more.
    public mutating func cancel() {
        isReloadOwed = false
    }
}
