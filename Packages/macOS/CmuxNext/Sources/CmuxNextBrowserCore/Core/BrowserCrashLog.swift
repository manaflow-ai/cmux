public import Foundation

/// One engine process that ended unexpectedly. Holds no page content: no
/// URL, title or typed text, only the process kind, reason and which tab
/// (by opaque id) lost its page.
public nonisolated struct BrowserCrashRecord: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        /// The engine's own callback for a tab (CEF OnRenderProcessTerminated).
        case engine
        /// The app saw a helper process exit (kqueue on the child).
        case process
    }

    public var date: Date
    /// Chromium process type: `renderer`, `gpu-process`, `utility`, or
    /// `extension` for an extension renderer.
    public var processType: String
    /// Chromium utility sub type (`network.mojom.NetworkService`), if any.
    public var subType: String?
    public var pid: Int32?
    public var reason: BrowserProcessExit.Reason
    public var code: Int?
    public var tab: BrowserTabID?
    public var source: Source

    public init(date: Date = Date(), processType: String, subType: String? = nil, pid: Int32? = nil,
                reason: BrowserProcessExit.Reason, code: Int? = nil, tab: BrowserTabID? = nil, source: Source) {
        self.date = date
        self.processType = processType
        self.subType = subType
        self.pid = pid
        self.reason = reason
        self.code = code
        self.tab = tab
        self.source = source
    }

    public var codeDescription: String? { BrowserProcessExit(reason: reason, code: code).codeDescription }
}

/// Recent engine process failures, newest last (bounded). Observers run on
/// the main actor for each new record (the App writes crash reports), and
/// helper-exit observers for each helper process's one end (the App sends
/// it to crash reporting, ``helperExited(_:)``).
public final class BrowserCrashLog {
    public static let capacity = 64
    public private(set) var records: [BrowserCrashRecord] = []
    /// Total records since launch (the ring keeps only `capacity`).
    public private(set) var total = 0
    private var observers: [UUID: (BrowserCrashRecord) -> Void] = [:]
    private var helperExitObservers: [UUID: (BrowserHelperExit) -> Void] = [:]

    public init() {}

    public func append(_ record: BrowserCrashRecord) {
        records.append(record)
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
        total += 1
        for observer in observers.values { observer(record) }
    }

    /// Returns a token; drop it with `removeObserver`.
    @discardableResult
    // raw-observer-allow: the log's own subscriber list (a direct registry, R-notif's target for a point-to-point broadcast), no notice center
    public func addObserver(_ observer: @escaping (BrowserCrashRecord) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    /// One helper process ended abnormally. Called once per process (a renderer shared by several tabs, or
    /// seen by both Chromium and the child monitor, is one end), where ``append(_:)`` keeps each tab's and
    /// each source's record.
    public func helperExited(_ exit: BrowserHelperExit) {
        for observer in helperExitObservers.values { observer(exit) }
    }

    /// Returns a token; drop it with `removeObserver`.
    @discardableResult
    public func addHelperExitObserver(_ observer: @escaping (BrowserHelperExit) -> Void) -> UUID {
        let id = UUID()
        helperExitObservers[id] = observer
        return id
    }

    /// Drops a record or helper-exit observer.
    public func removeObserver(_ id: UUID) {
        observers[id] = nil
        helperExitObservers[id] = nil
    }
}
