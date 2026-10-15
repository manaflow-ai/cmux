public import Foundation

/// What a Chromium pane shows instead of its page after the renderer
/// crashed or stopped responding, and when it brings the page back.
///
/// The panel feeds it the page's events and visibility changes; the view
/// reads ``failure``. A pane that was visible when its renderer ended waits
/// for an explicit Reload. A pane that was hidden restores its page when it
/// is shown again, within ``BrowserCrashReloadGuard``'s budget. WebKit panes
/// keep their own recovery (`BrowserPanel+WebContentTermination.swift`).
public struct ChromiumPageFailureState: Equatable, Sendable {
    public enum Failure: Equatable, Sendable {
        /// The renderer ended. `restoresWhenShown` is true when the pane was
        /// hidden and may bring the page back by itself once shown.
        case crashed(ChromiumCrashPageVariant, restoresWhenShown: Bool)
        /// The renderer stopped responding (Wait / Exit page).
        case unresponsive
    }

    public private(set) var failure: Failure?
    private var reloadGuard = BrowserCrashReloadGuard()
    private var lastCrash: Date?

    public init() {}

    /// Whether the pane covers its page with a crash or hang prompt now. A
    /// pane waiting to restore by itself shows nothing (it reloads on show).
    public var showsPrompt: Bool {
        switch failure {
        case .crashed(_, let restoresWhenShown): !restoresWhenShown
        case .unresponsive: true
        case nil: false
        }
    }

    /// Applies a page event.
    /// - Parameters:
    ///   - event: The event from ``BrowserPage/events``.
    ///   - now: The current time.
    ///   - paneVisible: Whether the pane is on screen now.
    public mutating func apply(_ event: BrowserPageEvent, at now: Date, paneVisible: Bool) {
        switch event {
        case .processTerminated(let exit):
            let variant = ChromiumCrashPageVariant(exit: exit, at: now, previousCrash: lastCrash)
            lastCrash = now
            let restores = reloadGuard.allowsAutomaticRestore(at: now, paneWasVisible: paneVisible)
            failure = .crashed(variant, restoresWhenShown: restores)
        case .unresponsiveChanged(let unresponsive):
            if unresponsive {
                if failure == nil { failure = .unresponsive }
            } else if failure == .unresponsive {
                failure = nil
            }
        case .navigationCommitted:
            // A new document committed: the page is back.
            failure = nil
        default:
            break
        }
    }

    /// The pane was shown. Returns true when the panel should reload the
    /// page now (it crashed while hidden and may restore by itself).
    public mutating func paneShown() -> Bool {
        guard case .crashed(_, true) = failure else { return false }
        failure = nil
        return true
    }

    /// The person pressed Reload on the crash page.
    public mutating func userReloaded() {
        failure = nil
        reloadGuard.reset()
    }

    /// The person answered "Page unresponsive". Wait clears the prompt (the
    /// engine raises it again if the page stays hung); Exit page keeps it
    /// until the renderer's end arrives as ``BrowserPageEvent/processTerminated(_:)``.
    public mutating func answeredUnresponsive(terminate: Bool) {
        guard failure == .unresponsive, !terminate else { return }
        failure = nil
    }
}
