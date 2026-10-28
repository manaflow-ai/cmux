import Foundation
public import Sentry

/// A Sentry event for a Chromium helper process (renderer, extension renderer, GPU, utility) that ended
/// abnormally while cmux kept running: Chrome counts the same ends by process type
/// (components/metrics/stability_metrics_helper.cc, `BrowserChildProcessCrashed`, `LogRendererCrash`).
/// One per process end, at most one per ``processType`` an hour (``HelperExitRateLimiter``).
///
/// Holds no page content by construction: no URL, title or tab, only Chromium's names for its helpers,
/// the reason, the code, the pid and the message pump's numbers. The pid is the one in the macOS crash
/// report (`.ips`, ``SystemCrashEvent``'s `pid` tag) and the minidump of the same process, so one search
/// finds all three. The event goes through the scrubber like every other (``CrashReporter/options()``).
public nonisolated struct HelperExitEvent: Sendable, Equatable {
    /// `renderer`, `extension`, `gpu`, `utility` or `other`: the grouping and the rate limit's key.
    public var processType: String
    /// The Chromium `--type=` value (`gpu-process`, `crashpad-handler`).
    public var chromiumType: String
    /// The utility sub type (`network.mojom.NetworkService`).
    public var subType: String?
    /// `crashed`, `killed`, `outOfMemory`, `launchFailed`, `integrityFailure` or `abnormal`.
    public var reason: String
    /// The raw `waitpid` status or Chromium's exit code.
    public var code: Int?
    /// The code as `SIGSEGV` or `exit 3`.
    public var codeName: String?
    public var pid: Int32?
    /// The message pump at the end: numbers and fixed states only, sent as `pump_<key>`.
    public var pump: [String: String]
    /// Ends of this type the limit held back since the last event of the type.
    public var heldBack: Int

    public init(processType: String, chromiumType: String, subType: String? = nil, reason: String, code: Int? = nil,
                codeName: String? = nil, pid: Int32? = nil, pump: [String: String] = [:], heldBack: Int = 0) {
        self.processType = processType
        self.chromiumType = chromiumType
        self.subType = subType
        self.reason = reason
        self.code = code
        self.codeName = codeName
        self.pid = pid
        self.pump = pump
        self.heldBack = heldBack
    }

    /// Error level: the app survived, the page or the service it hosted did not. Grouped by type and
    /// reason, never by pid or code.
    public func event() -> Event {
        let event = Event(level: .error)
        event.platform = "cocoa"
        let exception = Exception(value: "\(processType) helper ended: \(reason)", type: "ChromiumHelperExit")
        let mechanism = Mechanism(type: "cef_helper_exit")
        mechanism.handled = true
        exception.mechanism = mechanism
        event.exceptions = [exception]
        var tags = [
            "crash_source": "cef_helper_exit",
            "helper_type": processType,
            "helper_reason": reason,
            "chromium_type": chromiumType,
        ]
        if let subType { tags["helper_subtype"] = subType }
        if let pid { tags["pid"] = String(pid) }
        event.tags = tags
        var extra: [String: Any] = ["held_back": heldBack]
        if let code { extra["code"] = code }
        if let codeName { extra["code_name"] = codeName }
        for (key, value) in pump { extra["pump_" + key] = value }
        event.extra = extra
        event.fingerprint = ["cef_helper_exit", processType, reason]
        return event
    }
}

extension CrashReporter {
    /// Sends a Chromium helper's end, in a clean scope: the app's breadcrumbs describe the app, not the helper.
    /// Call off the main thread (the SDK writes the envelope). Does nothing when crash reporting is off.
    public nonisolated func reportHelperExit(_ exit: HelperExitEvent) {
        guard isStarted else { return }
        SentrySDK.capture(event: exit.event(), scope: Scope())
    }
}
