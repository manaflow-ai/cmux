public import CmuxNextCompat
import Foundation
public import Sentry

/// A crash-reporting event for a browser failure: a page's renderer ended
/// (the sad tab), its main-frame load failed (a net error page or
/// interstitial), or a helper with no tab (extension, GPU, utility) ended.
/// Carries no stack (the failure is in another process or on the network)
/// and no page content: only the page's scheme and host.
///
/// A renderer or helper end is an error, a load failure a warning. One issue
/// per kind, termination and code name, and per helper kind for a helper end
/// (``fingerprint``); the host is a tag, so one crash on many sites is one issue.
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

    /// The exception type: `RendererProcessTerminated`, `MainFrameLoadFailed`
    /// or `HelperProcessEnded`.
    public var exceptionType: String {
        switch failure.kind {
        case .rendererTerminated: "RendererProcessTerminated"
        case .loadFailed: "MainFrameLoadFailed"
        case .helperEnded: "HelperProcessEnded"
        }
    }

    /// The exception value: `renderer crashed SIGTRAP`, `ERR_NAME_NOT_RESOLVED (-105)`,
    /// `extension crashed SIGTRAP`.
    public var summary: String {
        switch failure.kind {
        case .rendererTerminated:
            return ["renderer", failure.termination ?? "ended", failure.codeName].compactMap { $0 }.joined(separator: " ")
        case .loadFailed:
            let name = failure.codeName ?? "net error"
            return "\(name) (\(failure.code))" + (failure.interstitial ? " interstitial" : "")
        case .helperEnded:
            return [failure.processKind ?? "helper", failure.termination ?? "ended", failure.codeName].compactMap { $0 }.joined(separator: " ")
        }
    }

    /// The grouping: kind, termination and code name, plus the helper kind
    /// for a helper end; never the host.
    public var fingerprint: [String] {
        var parts = ["browser_failure", failure.kind.rawValue]
        if failure.kind == .helperEnded { parts.append(failure.processKind ?? "-") }
        return parts + [failure.termination ?? "-", failure.codeName ?? String(failure.code)]
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
        let event = Event(level: failure.kind == .loadFailed ? .warning : .error)
        event.platform = "cocoa"
        let exception = Exception(value: summary, type: exceptionType)
        let mechanismType = switch failure.kind {
        case .rendererTerminated: "cef_render_process_terminated"
        case .loadFailed: "cef_load_error"
        case .helperEnded: "cef_helper_process_ended"
        }
        let mechanism = Mechanism(type: mechanismType)
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
