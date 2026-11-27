public import CMUXMobileCore
public import Foundation

/// The macOS product analytics emitter.
///
/// Every method is synchronous, non-throwing and returns immediately: it
/// enqueues a command and an off-main actor does the work in call order, so
/// call sites never block typing, rendering or drag and drop. When disabled
/// (telemetry opt-out, managed `DisableTelemetry`, XCTest), every method is a
/// no-op and nothing is enqueued.
///
/// The app builds one instance at its composition root with a PostHog sink.
/// Tests build their own with a recording sink and a suite `UserDefaults`:
///
/// ```swift
/// let sink = RecordingAnalyticsSink()
/// let analytics = ProductAnalytics(
///     isEnabled: true,
///     sink: sink,
///     ledger: ProductAnalyticsLedger(defaults: UserDefaults(suiteName: #function)!),
///     context: ProductAnalyticsContext(appVersion: "1.0", appBuild: "1", channel: "dev", osVersion: "15.0")
/// )
/// analytics.track(.signInStarted)
/// await analytics.drain()
/// ```
public final class ProductAnalytics: Sendable {
    /// Whether this instance sends anything. Frozen for its lifetime, like
    /// the telemetry setting it comes from.
    public let isEnabled: Bool
    private let continuation: AsyncStream<ProductAnalyticsCommand>.Continuation?

    /// An instance that drops everything, for previews and tests that do not
    /// observe analytics.
    public static let disabled = ProductAnalytics()

    private init() {
        isEnabled = false
        continuation = nil
    }

    /// Creates an emitter and records this launch (first launch, version change).
    ///
    /// - Parameters:
    ///   - isEnabled: False for opt-out, managed telemetry off, or tests.
    ///   - sink: Where events go.
    ///   - ledger: Persistent dedupe and attribution state.
    ///   - context: The shared properties at launch.
    ///   - isPreexistingInstall: True when the app ran before this catalog
    ///     existed, so its first launch is not reported now.
    ///   - now: The clock. Defaults to the system clock.
    public init(
        isEnabled: Bool,
        sink: any AnalyticsEmitting,
        ledger: ProductAnalyticsLedger,
        context: ProductAnalyticsContext,
        isPreexistingInstall: Bool = false,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.isEnabled = isEnabled
        guard isEnabled else {
            continuation = nil
            return
        }
        let (stream, continuation) = AsyncStream.makeStream(of: ProductAnalyticsCommand.self)
        self.continuation = continuation
        let pipeline = ProductAnalyticsPipeline(
            sink: sink,
            ledger: ledger,
            context: context,
            isPreexistingInstall: isPreexistingInstall,
            now: now
        )
        Task.detached(priority: .utility) {
            await pipeline.run(stream)
        }
        continuation.yield(.launch)
    }

    deinit {
        continuation?.finish()
    }

    /// Records `event`. Impressions (`cmux_upgrade_prompt_shown` per source,
    /// `cmux_cloud_button_shown`) are deduplicated per launch.
    public func track(_ event: ProductAnalyticsEvent) {
        continuation?.yield(.track(event))
    }

    /// Records `milestone` the first time it is reached on this install.
    public func reach(_ milestone: ActivationMilestone) {
        continuation?.yield(.milestone(milestone))
    }

    /// Records a use of `feature`, at most once per UTC day.
    public func featureUsed(_ feature: ProductFeature) {
        continuation?.yield(.feature(feature))
    }

    /// Updates one shared property for this and later events.
    public func updateContext(_ change: ProductAnalyticsContextChange) {
        continuation?.yield(.context(change))
    }

    /// Marks later events signed in and tells the sink the account once per
    /// change. The sink may own the person identity or, like the Mac app's,
    /// leave identity and team groups to the host's sign-in identity
    /// observer, the only place that also resets them on sign-out.
    ///
    /// - Parameter userID: The account's Stack user id, the same distinct id
    ///   the server's billing events use.
    public func identify(userID: String) {
        continuation?.yield(.identify(userID: userID))
    }

    /// Records `cmux_signed_out` once and tells the sink the account is gone.
    /// Call it before the sign-out runs so the event joins the signed-in person.
    public func signedOut() {
        continuation?.yield(.signOut)
    }

    /// Reports the signed-in account's plan; fires `cmux_plan_activated` or
    /// `cmux_plan_deactivated` on a change.
    public func notePlan(accountID: String, isPaid: Bool) {
        continuation?.yield(.plan(accountID: accountID, isPaid: isPaid))
    }

    /// Reports one agent hook. The session id is used only for dedupe and is
    /// never sent.
    public func noteAgentHook(source: String, sessionID: String, phase: AgentHookPhase) {
        continuation?.yield(.agentHook(source: source, sessionID: sessionID, phase: phase))
    }

    /// Reports one finished Cloud VM API request.
    public func noteCloudRequest(_ request: CloudRequestObservation) {
        continuation?.yield(.cloudRequest(request))
    }

    /// Reports a finished Cloud machine create from any launcher.
    ///
    /// - Parameters:
    ///   - succeeded: The machine was created (even if opening it then failed).
    ///   - errorCode: The server's refusal code on failure, or nil when unknown.
    ///   - seconds: From submit to finish.
    public func noteMachineCreateFinished(succeeded: Bool, errorCode: String?, seconds: Double) {
        continuation?.yield(.machineCreateFinished(succeeded: succeeded, errorCode: errorCode, seconds: seconds))
    }

    /// Waits until every command enqueued before this call has been processed.
    /// For tests and shutdown; never call on a hot path.
    public func drain() async {
        guard let continuation else { return }
        await withCheckedContinuation { (resume: CheckedContinuation<Void, Never>) in
            continuation.yield(.barrier(resume))
        }
    }
}
