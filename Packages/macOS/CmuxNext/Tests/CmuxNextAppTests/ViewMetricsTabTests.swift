import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFeatures
import Foundation
import Testing

/// View Metrics (`diagnostics.viewMetrics`) opens its viewer tab in the action's own turn (zero-latency.md,
/// "Native actions: the budget contract"): before, it was a `.waiting(.fileSystem)` effect and the tab
/// opened only once the JSON was written off the main thread. The tab shows at once, its page loading
/// until the file is written; the run is never counted as waiting.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3)), .enabled(if: SameTreeDaemonBinary.url != nil, "needs the same-tree cmux-tui"))
struct ViewMetricsTabTests {
    /// View Metrics bound with its feature on (the launch's features may have it off).
    static func bindMetrics(_ services: AppServices) {
        services.features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                        overrides: FeatureOverrides(environmentEnabled: ["metricsView"]))
        HangReportsHandlers.bind(into: services.registry, context: AppActionContext(services: services))
    }

    /// The code editor tab showing the metrics file, if any.
    static func metricsTab(_ services: AppServices) -> String? {
        services.viewers.editorPages.tabs.first { $0.value.file?.path.hasSuffix("Metrics/metrics.json") == true }?.key
    }

    /// Runs View Metrics on `pane`, returning its refusal and its tracked work.
    static func run(_ services: AppServices, on pane: PaneModel) -> (String?, [ActionWork]) {
        let invocation = ActionInvocation(target: ActionTargetRef(kind: .pane, id: pane.id), origin: .cli)
        var work: [ActionWork] = []
        let refusal = services.registry.capturingRefusal {
            work = services.registry.capturingWork { _ = services.registry.perform("diagnostics.viewMetrics", invocation: invocation) }
        }
        return (refusal, work)
    }

    @Test func theViewerTabOpensInTheActionsTurn() async throws {
        try await PinnedPageTests.withApp { services, _ in
            Self.bindMetrics(services)
            let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            let (refusal, work) = Self.run(services, on: pane)
            #expect(refusal == nil, "View Metrics was refused: \(refusal ?? "")")
            // Read in the action's own turn: nothing was awaited since the perform.
            #expect(Self.metricsTab(services) != nil, "no viewer tab in the action's turn")
            #expect(services.registry.waitingRuns["diagnostics.viewMetrics"] == nil, "the run was counted as showing nothing until the write")
            for task in work { _ = await task.value }
        }
    }
}
