public import CmuxNextCompat
import Foundation
public import Sentry

/// A crash-reporting event for a browser failure the person saw: a page's
/// renderer ended (the sad tab) or its main-frame load failed (a net error
/// page or interstitial). Carries no stack (the failure is in another
/// process or on the network) and no page content: only the page's scheme
/// and host.
///
/// A renderer end is an error, a load failure a warning. One issue per kind,
/// termination and code name (``fingerprint``); the host is a tag, so one
/// crash on many sites is one issue.
public nonisolated struct BrowserFailureEvent: Sendable, Equatable {
    /// The failure.
    public let failure: BrowserEngineFailure
    /// How many failures with this key the launch has seen, this one included
    /// (``BrowserFailureThrottle``).
    public let count: Int

    /// - Parameters:
    ///   - failure: The failure.
    ///   - count: The key's count so far (1 for the first).
    public init(failure: BrowserEngineFailure, count: Int = 1) {
        self.failure = failure
        self.count = count
    }

    /// The exception type: `RendererProcessTerminated` or `MainFrameLoadFailed`.
    public var exceptionType: String {
        switch failure.kind {
        case .rendererTerminated: "RendererProcessTerminated"
        case .loadFailed: "MainFrameLoadFailed"
        }
    }

    /// The exception value: `renderer crashed SIGTRAP`, `ERR_NAME_NOT_RESOLVED (-105)`.
    public var summary: String {
        switch failure.kind {
        case .rendererTerminated:
            return ["renderer", failure.termination ?? "ended", failure.codeName].compactMap { $0 }.joined(separator: " ")
        case .loadFailed:
            let name = failure.codeName ?? "net error"
            return "\(name) (\(failure.code))" + (failure.interstitial ? " interstitial" : "")
        }
    }

    /// The grouping: kind, termination and code name, never the host.
    public var fingerprint: [String] {
        ["browser_failure", failure.kind.rawValue, failure.termination ?? "-", failure.codeName ?? String(failure.code)]
    }

    /// The tags: what failed, its code, the site and the engine versions.
    public var tags: [String: String] {
        var tags = [
            "browser_failure": failure.kind.rawValue,
            "error_code": String(failure.code),
        ]
        if let name = failure.codeName { tags["error_name"] = name }
        if let termination = failure.termination { tags["termination_status"] = termination }
        if let site = failure.site { tags["site"] = site }
        if let kind = failure.processKind { tags["process_kind"] = kind }
        if failure.kind == .loadFailed { tags["interstitial"] = failure.interstitial ? "yes" : "no" }
        if let cef = failure.versions.cef { tags["cef_version"] = cef }
        if let chromium = failure.versions.chromium { tags["chromium_version"] = chromium }
        if let fork = failure.versions.forkAPI { tags["cef_fork_api"] = String(fork) }
        return tags
    }

    /// Builds the event.
    public func event() -> Event {
        let event = Event(level: failure.kind == .rendererTerminated ? .error : .warning)
        event.platform = "cocoa"
        let exception = Exception(value: summary, type: exceptionType)
        let mechanism = Mechanism(type: failure.kind == .rendererTerminated ? "cef_render_process_terminated" : "cef_load_error")
        mechanism.handled = true
        exception.mechanism = mechanism
        event.exceptions = [exception]
        event.fingerprint = fingerprint
        event.tags = tags
        var extra: [String: Any] = ["count": count, "error_code": failure.code]
        if let reason = failure.reason { extra["reason"] = reason }
        event.extra = extra
        return event
    }
}
