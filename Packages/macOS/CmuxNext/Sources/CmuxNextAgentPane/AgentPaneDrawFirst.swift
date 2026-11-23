public import AppKit
import CmuxNextCompat

/// A page that replaces one in sight draws before it shows (cmux#48660, Austin 2026-11-20, on a Cloud chat's start:
/// "it looks fine for a second, then the pane goes blank with only a centered spinner, then eventually loads").
///
/// A Cloud start's tab shows the person's prompt, the start's steps and the composer until the machine's chat takes
/// its place. That chat's page drew out of sight first (``AgentPaneView/paintParked(in:size:within:)``), but only when
/// its tab could make the page right then, and only for 8 s; otherwise it showed unpainted, which is the pane's loading
/// cover (``AgentPaneLoadingView``): the page's background with the busy mark in the middle, no chat and no composer.
/// ``draw(_:makeable:in:size:within:)`` waits for the page to be makeable, then for its first paint, both within one
/// bound (``bound``), and the caller keeps what shows until it returns.
public struct AgentPaneDrawFirst {
    public init() {}
    /// The longest the page in sight stays for its replacement. Past the page's own last resort (App.tsx
    /// `CHAT_DRAW_HOLD_MS`, 10 s after its handshake, when it reports its first paint whether its chat is read or not)
    /// plus a cold page load and the handshake: a page that has said nothing by then shows as it is.
    public static let bound: Duration = .seconds(20)

    /// How the page went before it showed. `rawValue` names it on a Cloud send's timeline (names only).
    public enum Outcome: String, Equatable, Sendable, CaseIterable {
        /// It painted out of sight, so it shows drawn: no cover, no fade.
        case painted = "page painted"
        /// It did not paint within the bound and shows as it is.
        case unpainted = "page unpainted"
        /// No page could be made for it within the bound.
        case noPage = "page not made"
    }

    /// Makes the page with `page` once `makeable` holds, lays it out of sight in `window` at `size` and returns once it
    /// painted, or after `limit` (both waits share it).
    @MainActor
    public static func draw(_ page: @MainActor () -> AgentPaneView?, makeable: @escaping @MainActor @Sendable () -> Bool,
                            in window: NSWindow, size: CGSize, within limit: Duration = bound) async -> Outcome {
        let began = ContinuousClock.now
        guard await holds(within: limit, makeable), let view = page() else { return .noPage }
        let left = limit - began.duration(to: .now)
        guard left > .zero else { return view.model.hasPainted ? .painted : .unpainted }
        return await view.paintParked(in: window, size: size, within: left) ? .painted : .unpainted
    }

    /// Whether `condition` holds now or comes to hold within `limit`; false after it, or when cancelled.
    @MainActor
    public static func holds(within limit: Duration, _ condition: @escaping @MainActor @Sendable () -> Bool) async -> Bool {
        if condition() { return true }
        let watcher = Task { // on the main actor, as the caller (no hop): it only reads `condition`
            for await held in ObservationStream(condition) where held { return true }
            return false // cancelled by the bound below
        }
        let bound = Task {
            // wakeup-allow: one-shot bound on a replacing page becoming makeable before it shows anyway
            try? await Task.sleep(for: limit)
            watcher.cancel()
        }
        defer { bound.cancel() }
        return await withTaskCancellationHandler { await watcher.value } onCancel: { watcher.cancel() }
    }
}
