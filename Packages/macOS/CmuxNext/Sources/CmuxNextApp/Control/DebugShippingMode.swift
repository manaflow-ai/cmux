#if DEBUG || CMUX_BENCH_HOOKS
import CmuxNextControl
import CmuxNextCrashReporting
import CmuxNextDesign
import CmuxNextHangReports
import CmuxNextPages
import CmuxNextSettings
import Foundation

/// `debug.shipping_mode` (p14-energy-100): what this launch really runs of the shipping
/// configuration `scripts/cmux-next/idle-budget.py` measures, read from the app, not predicted
/// from the launch environment.
///
/// - `draws_when_occluded`: ``WindowDrawPolicy/drawsWhenOccluded`` (terminals and native surfaces).
/// - `pages_render_when_covered`: `PageWebView.rendersWhenCovered` for this launch (React pages).
/// - `sentry_should_start`: the crash reporting policy starts Sentry in this launch.
/// - `hang_reports`: `available` (this build can send at all: NIGHTLY, or DEV with
///   `CMUX_NEXT_DEV_HANG_REPORTS=1`), `setting` (`diagnostics.hangReports`), `decision` (the ask
///   policy's: `send`, `confirm`, `invite`, `off`) and `enabled` (the service records and sends).
struct DebugShippingMode: Sendable {
    typealias JSONValue = CmuxNextSettings.JSONValue

    /// The main-actor part, copied in one turn.
    struct Snapshot: Sendable {
        var drawsWhenOccluded: Bool
        var pagesRenderWhenCovered: Bool
        var sentryShouldStart: Bool
        var hangReportsAvailable: Bool
        var hangReportsSetting: Bool?
        var hangReportsDecision: HangReportAskPolicy.Decision?
        var hangReportService: HangReportService?
    }

    let read: @MainActor @Sendable () -> Snapshot

    /// The method over this process's services and hang report controller.
    @MainActor static func live(services: AppServices) -> DebugShippingMode {
        DebugShippingMode { [weak services] in
            let controller = AppProcessRoot.shared.hangReports
            let setting = services?.settings?.snapshot.hangReports
            return Snapshot(
                drawsWhenOccluded: WindowDrawPolicy.drawsWhenOccluded,
                pagesRenderWhenCovered: PageWebView.rendersWhenCovered(ProcessInfo.processInfo.environment),
                sentryShouldStart: services?.crashReporting.reporter.policy.shouldStart ?? false,
                hangReportsAvailable: controller?.isAvailable ?? false,
                hangReportsSetting: setting,
                hangReportsDecision: controller?.isAvailable == true
                    ? setting.map { HangReportsController.decision(defaults: .standard, settingOn: $0) } : nil,
                hangReportService: controller?.service)
        }
    }

    var method: ControlMethod {
        .async("debug.shipping_mode") { [read] _ in
            let snapshot = await read()
            let enabled = await snapshot.hangReportService?.isEnabled ?? false
            return Self.render(snapshot, hangReportsEnabled: enabled)
        }
    }

    static func render(_ snapshot: Snapshot, hangReportsEnabled: Bool) -> JSONValue {
        [
            "draws_when_occluded": .bool(snapshot.drawsWhenOccluded),
            "pages_render_when_covered": .bool(snapshot.pagesRenderWhenCovered),
            "sentry_should_start": .bool(snapshot.sentryShouldStart),
            "hang_reports": [
                "available": .bool(snapshot.hangReportsAvailable),
                "setting": snapshot.hangReportsSetting.map(JSONValue.bool) ?? .null,
                "decision": snapshot.hangReportsDecision.map { JSONValue.string(Self.name($0)) } ?? .null,
                "enabled": .bool(hangReportsEnabled),
            ],
        ]
    }

    static func name(_ decision: HangReportAskPolicy.Decision) -> String {
        switch decision {
        case .send: "send"
        case .confirm: "confirm"
        case .invite: "invite"
        case .off: "off"
        }
    }
}
#endif
