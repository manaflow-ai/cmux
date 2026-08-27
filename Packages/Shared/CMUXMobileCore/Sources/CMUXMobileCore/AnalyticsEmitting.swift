import Foundation

/// The fire-and-forget analytics seam every iOS fire-site depends on.
///
/// This is the single injection point for product analytics in the mobile app.
/// It lives in `CMUXMobileCore` (the universally-imported, dependency-free base
/// package) so the lowest fire-site — `MobileClientIDRepository` in
/// `CmuxMobileShellModel` — can depend on the seam without any upward edge. The
/// concrete `AnalyticsEmitter` actor lives in `CmuxMobileAnalytics`, is built
/// once at the app composition root, and is injected here as `any
/// AnalyticsEmitting`. Tests and SwiftUI previews use ``NoopAnalytics`` or a
/// recording fake.
///
/// ### Non-blocking contract
///
/// ``capture(_:_:)`` is **synchronous, non-throwing, and returns immediately**.
/// It must never be `await`-ed inline on a hot path (terminal input, render),
/// and conformers must never do network or disk I/O on the calling thread:
/// `capture` enqueues onto an off-main actor and returns. Fire-sites call
/// `analytics.capture("ios_event", props)` with **no `await`**.
///
/// ```swift
/// // On the terminal-input hot path — note: no await.
/// analytics.capture("ios_terminal_input_submitted", [
///     "byte_count": .int(payload.utf8.count),
///     "line_count": .int(lineCount),
/// ])
/// ```
public protocol AnalyticsEmitting: Sendable {
    /// Records a single product event. Returns immediately; emission is async.
    ///
    /// - Parameters:
    ///   - event: The `ios_`-prefixed snake_case event name.
    ///   - properties: Event properties. Sizes, counts, durations, flags, and
    ///     short enum strings only — never user content.
    func capture(_ event: String, _ properties: [String: AnalyticsValue])

    /// Associates subsequent events with a stable user identity.
    ///
    /// Called once at sign-in completion so the pre-auth anonymous funnel merges
    /// into the authenticated user profile.
    ///
    /// - Parameters:
    ///   - userId: The stable identifier (the Stack user id), or `nil` to reset
    ///     to anonymous on sign-out.
    ///   - alias: A prior anonymous id to alias into `userId`, if any.
    ///   - properties: Person properties to set on the identified profile.
    func identify(userId: String?, alias: String?, properties: [String: AnalyticsValue])

    /// Sets super-properties merged into every subsequent event.
    ///
    /// Super-properties (app version, OS, device model, paired-mac count, …) are
    /// set once at identity and refreshed only when they change, never repeated
    /// per `capture` call by the caller.
    ///
    /// - Parameter properties: The super-properties to merge and persist.
    func setSuperProperties(_ properties: [String: AnalyticsValue])

    /// Flushes any buffered events immediately.
    ///
    /// Awaited at app-background so queued events survive suspension. On hot
    /// paths, never call this — rely on the size/cadence triggers instead.
    func flush() async
}

extension AnalyticsEmitting {
    /// Records an event with no properties.
    public func capture(_ event: String) {
        capture(event, [:])
    }

    /// Associates a user identity with no alias or person properties.
    public func identify(userId: String?) {
        identify(userId: userId, alias: nil, properties: [:])
    }
}
