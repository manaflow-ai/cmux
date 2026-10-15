public import Foundation

/// One engine process that ended unexpectedly.
///
/// Holds no page content (no URL, title or typed text): only the process
/// kind, the reason, and which pane (by opaque id) lost its page.
public struct BrowserCrashRecord: Hashable, Sendable {
    public enum Source: String, Hashable, Sendable {
        /// The engine's own callback for a pane (CEF OnRenderProcessTerminated,
        /// WebKit webViewWebContentProcessDidTerminate).
        case engine
        /// The app saw a helper process exit (kqueue on the child).
        case process
    }

    public var date: Date
    /// Chromium process type (`renderer`, `gpu-process`, `utility`,
    /// `extension`), or `webcontent` for WebKit.
    public var processType: String
    /// Chromium utility sub type (`network.mojom.NetworkService`), if any.
    public var subType: String?
    public var pid: Int32?
    public var reason: BrowserProcessExit.Reason
    public var code: Int?
    /// The browser pane that lost its page, if one did.
    public var panelID: UUID?
    public var source: Source

    public init(
        date: Date = Date(),
        processType: String,
        subType: String? = nil,
        pid: Int32? = nil,
        reason: BrowserProcessExit.Reason,
        code: Int? = nil,
        panelID: UUID? = nil,
        source: Source
    ) {
        self.date = date
        self.processType = processType
        self.subType = subType
        self.pid = pid
        self.reason = reason
        self.code = code
        self.panelID = panelID
        self.source = source
    }

    public var codeDescription: String? { BrowserProcessExit(reason: reason, code: code).codeDescription }
}

/// Recent engine process failures, newest last, bounded. Read by the debug
/// socket (`debug.browser.crashes`) and crash-injection tests.
@MainActor
public final class BrowserCrashLog {
    public static let shared = BrowserCrashLog()
    public static let capacity = 64

    public private(set) var records: [BrowserCrashRecord] = []
    /// Total records since launch (the ring keeps only `capacity`).
    public private(set) var total = 0
    private var observers: [UUID: (BrowserCrashRecord) -> Void] = [:]

    public init() {}

    public func append(_ record: BrowserCrashRecord) {
        records.append(record)
        if records.count > Self.capacity { records.removeFirst(records.count - Self.capacity) }
        total += 1
        for observer in observers.values { observer(record) }
    }

    /// Returns a token; drop it with `removeObserver`.
    @discardableResult
    public func addObserver(_ observer: @escaping (BrowserCrashRecord) -> Void) -> UUID {
        let id = UUID()
        observers[id] = observer
        return id
    }

    public func removeObserver(_ id: UUID) {
        observers[id] = nil
    }
}
