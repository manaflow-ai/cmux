public import CmuxNextSettings

/// `debug.shipping_mode`: what this launch really runs of the shipping
/// configuration `scripts/cmux-next/idle-budget.py` measures, read from the app, not predicted
/// from the launch environment.
///
/// - `draws_when_occluded`: `WindowDrawPolicy.drawsWhenOccluded` (terminals and native surfaces).
/// - `pages_render_when_covered`: `PageWebView.rendersWhenCovered` for this launch (React pages).
/// - `sentry_should_start`: the crash reporting policy starts Sentry in this launch.
/// - `hang_reports`: `available` (this build can send at all: NIGHTLY, or DEV with
///   `CMUX_NEXT_DEV_HANG_REPORTS=1`), `setting` (`diagnostics.hangReports`), `decision` (the ask
///   policy's: `send`, `confirm`, `invite`, `off`), `enabled` (the service records and sends) and
///   `daemon_metrics_fold` (how often each outcome of folding the daemon's metrics file into a report happened
///   this launch: `folded`, `samples`, `missing`, `no_daemon`, ...; null where nothing is folded).
///
/// The App registers ``method`` next to `debug.energy` with a ``State`` reader over its services.
public struct ShippingModeReport: Sendable {
    public typealias JSONValue = CmuxNextSettings.JSONValue

    /// Reads the state; nil once the services are gone.
    let state: @Sendable () async -> State?

    public init(state: @escaping @Sendable () async -> State?) {
        self.state = state
    }

    /// `debug.shipping_mode`.
    public var method: ControlMethod { .async("debug.shipping_mode") { [state] _ in await state().map(\.json) ?? .null } }

    /// What the launch runs.
    public struct State: Sendable, Equatable {
        public var drawsWhenOccluded: Bool
        public var pagesRenderWhenCovered: Bool
        public var sentryShouldStart: Bool
        public var hangReports: HangReports

        public init(drawsWhenOccluded: Bool, pagesRenderWhenCovered: Bool, sentryShouldStart: Bool, hangReports: HangReports) {
            self.drawsWhenOccluded = drawsWhenOccluded
            self.pagesRenderWhenCovered = pagesRenderWhenCovered
            self.sentryShouldStart = sentryShouldStart
            self.hangReports = hangReports
        }

        public var json: JSONValue {
            [
                "draws_when_occluded": .bool(drawsWhenOccluded),
                "pages_render_when_covered": .bool(pagesRenderWhenCovered),
                "sentry_should_start": .bool(sentryShouldStart),
                "hang_reports": hangReports.json,
            ]
        }
    }

    /// The hang reports controller's state.
    public struct HangReports: Sendable, Equatable {
        public var available: Bool
        /// `diagnostics.hangReports`; nil before the settings load.
        public var setting: Bool?
        /// The ask policy's decision (`send`, `confirm`, `invite`, `off`); nil where nothing can send.
        public var decision: String?
        public var enabled: Bool
        /// Each outcome of the daemon metrics fold (task 062) by name, with its count this launch; nil where nothing
        /// is folded.
        public var daemonMetricsFold: [String: UInt64]?

        public init(available: Bool, setting: Bool?, decision: String?, enabled: Bool, daemonMetricsFold: [String: UInt64]? = nil) {
            self.available = available
            self.setting = setting
            self.decision = decision
            self.enabled = enabled
            self.daemonMetricsFold = daemonMetricsFold
        }

        var json: JSONValue {
            [
                "available": .bool(available),
                "setting": setting.map(JSONValue.bool) ?? .null,
                "decision": decision.map(JSONValue.string) ?? .null,
                "enabled": .bool(enabled),
                "daemon_metrics_fold": daemonMetricsFold.map { counts in
                    JSONValue.object(counts.mapValues { JSONValue.number(Double($0)) })
                } ?? .null,
            ]
        }
    }
}
