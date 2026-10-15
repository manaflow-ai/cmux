public import Foundation

/// Why a Chromium panel's renderer process ended while its page was open
/// (Chrome's "sad tab"). The panel keeps its URL and history; Reload starts a
/// new renderer.
///
/// A Chromium panel uses Chrome's own words ("Aw, Snap!", "Something went
/// wrong while displaying this webpage.", the error code, Reload), so a page
/// that crashes in cmux reads like the same page crashing in Chrome. WebKit
/// panels keep their own recovery prompt.
///
/// Reference: cmux Next `CmuxNextBrowser/Core/BrowserProcessExit.swift`,
/// `UI/Strings+PageFailure.swift` and the `chromium-aw-snap-wording` release note.
public struct ChromiumPageGone: Hashable, Sendable {
    public enum Reason: String, Hashable, Sendable, CaseIterable {
        /// The process crashed (a signal such as SIGSEGV, or a CHECK).
        case crashed
        /// Something outside the page ended it (`kill`, Activity Monitor, the system).
        case killed
        case outOfMemory
        /// The process could not start.
        case launchFailed
        /// Code signature or integrity check failed.
        case integrityFailure
        /// Ended with a non-zero exit code for another reason.
        case abnormal
    }

    public var reason: Reason
    /// Raw `waitpid` status or exit code, when Chromium reports one.
    public var code: Int?

    public init(reason: Reason, code: Int? = nil) {
        self.reason = reason
        self.code = code
    }

    /// Maps CEF's `cef_termination_status_t` (TS_ABNORMAL_TERMINATION = 0,
    /// TS_PROCESS_WAS_KILLED, TS_PROCESS_CRASHED, TS_PROCESS_OOM,
    /// TS_LAUNCH_FAILED, TS_INTEGRITY_FAILURE).
    public init(cefStatus status: Int, code: Int) {
        let reason: Reason = switch status {
        case 1: .killed
        case 2: .crashed
        case 3: .outOfMemory
        case 4: .launchFailed
        case 5: .integrityFailure
        default: .abnormal
        }
        self.init(reason: reason, code: code == 0 ? nil : code)
    }

    /// Error code text: "SIGSEGV" when the process ended from a signal,
    /// "exit 3" for an exit status. CEF reports the raw `waitpid` status on
    /// macOS.
    public var codeDescription: String? {
        guard let code, code > 0 else { return nil }
        let signal = code & 0x7f
        if signal != 0, signal != 0x7f {
            return Self.signalName(signal) ?? "signal \(signal)"
        }
        let status = (code >> 8) & 0xff
        return status != 0 ? "exit \(status)" : String(code)
    }

    static func signalName(_ signal: Int) -> String? {
        switch signal {
        case 1: "SIGHUP"
        case 2: "SIGINT"
        case 3: "SIGQUIT"
        case 4: "SIGILL"
        case 5: "SIGTRAP"
        case 6: "SIGABRT"
        case 8: "SIGFPE"
        case 9: "SIGKILL"
        case 10: "SIGBUS"
        case 11: "SIGSEGV"
        case 13: "SIGPIPE"
        case 15: "SIGTERM"
        default: nil
        }
    }

    /// The title: Chrome's "Aw, Snap!" (IDS_SAD_TAB_TITLE), or "Can't open this
    /// page" (IDS_SAD_TAB_RELOAD_TITLE) when the page crashed again soon after
    /// a reload (`ChromiumCrashHistory`).
    public func title(repeated: Bool) -> String {
        repeated
            ? String(localized: "browser.chromium.pageGone.repeatedTitle",
                     defaultValue: "Can\u{2019}t open this page", bundle: .module)
            : String(localized: "browser.chromium.pageGone.title", defaultValue: "Aw, Snap!", bundle: .module)
    }

    /// The body: Chrome's "Something went wrong while displaying this
    /// webpage." (IDS_SAD_TAB_MESSAGE); for a repeated out-of-memory crash,
    /// "Try closing other tabs or programs to free up memory." (IDS_SAD_TAB_RELOAD_CLOSE_TABS).
    public func message(repeated: Bool) -> String {
        if repeated, reason == .outOfMemory {
            return String(localized: "browser.chromium.pageGone.outOfMemoryMessage",
                          defaultValue: "Try closing other tabs or programs to free up memory.", bundle: .module)
        }
        return String(localized: "browser.chromium.pageGone.message",
                      defaultValue: "Something went wrong while displaying this webpage.", bundle: .module)
    }

    /// "Error code: SIGSEGV", nil when Chromium reported no code.
    public var errorCodeLine: String? {
        codeDescription.map { code in
            String(format: String(localized: "browser.chromium.pageGone.errorCode",
                                  defaultValue: "Error code: %@", bundle: .module), code)
        }
    }
}

extension ChromiumPageGone {
    /// The sad tab for an engine-neutral process exit (`BrowserPageEvent.processTerminated`).
    public init(_ exit: BrowserPageProcessExit) {
        let reason: Reason = switch exit.kind {
        case .crashed: .crashed
        case .killed: .killed
        case .outOfMemory: .outOfMemory
        case .launchFailed: .launchFailed
        case .other: .abnormal
        }
        self.init(reason: reason, code: exit.status.map(Int.init))
    }
}

/// When a Chromium panel's renderer last ended, so the sad tab can tell a
/// crash right after a reload from a first crash (Chrome's
/// `SadTab::ShouldShowFeedbackButton` window: 10 seconds).
public struct ChromiumCrashHistory: Equatable, Sendable {
    /// A crash this soon after the previous one is a repeat.
    public static let repeatWindow: TimeInterval = 10

    private var lastCrash: Date?

    public init() {}

    /// Records a crash at `date` and returns whether it repeats the previous one.
    public mutating func record(at date: Date) -> Bool {
        defer { lastCrash = date }
        guard let lastCrash else { return false }
        return date.timeIntervalSince(lastCrash) < Self.repeatWindow
    }
}
