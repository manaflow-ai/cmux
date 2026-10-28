import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextFeatures
import CmuxNextPages
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

    /// The same, with a metrics write that always fails.
    static func bindFailingMetrics(_ services: AppServices) {
        services.features = FeatureList(registry: FeatureRegistry(), channel: .dev,
                                        overrides: FeatureOverrides(environmentEnabled: ["metricsView"]))
        HangReportsHandlers.bind(into: services.registry, context: AppActionContext(services: services),
                                 writeMetrics: { _ in throw Refused() })
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

    private struct Refused: LocalizedError {
        var errorDescription: String? { "the test refused the metrics write" }
    }

    /// A failed write is reported, and the tab's page fails with its reason (its read waits for the write).
    @Test func aFailedWriteFailsTheTabsPageWithItsReason() async throws {
        try await PinnedPageTests.withApp { services, _ in
            Self.bindFailingMetrics(services)
            let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            let (refusal, work) = Self.run(services, on: pane)
            #expect(refusal == nil, "View Metrics was refused: \(refusal ?? "")")
            let key = try #require(Self.metricsTab(services), "no viewer tab in the action's turn")
            var failures: [String] = []
            for task in work { if let failure = await task.value { failures.append(failure.message) } }
            #expect(failures.joined(separator: " | ").contains("the test refused the metrics write"), "the failure was not reported: \(failures)")
            // The tab's page waits for the write: the gate is its provider's, or the service's until the page is made.
            let pages = services.viewers.editorPages
            let file = try #require(pages.tabs[key]?.file)
            let ready = try #require(pages.pendingWrites[file] ?? pages.tabs[key]?.provider?.ready, "the tab's read does not wait for the write")
            let reason = await ready()
            #expect(reason?.contains("the test refused the metrics write") == true, "the tab's page would not fail with the write's reason: \(reason ?? "nil")")
        }
    }
    /// The tab's page (its `cmux.editor.config`, what the page loads), once the pane made it.
    static func readPage(_ services: AppServices, _ key: String) async throws -> Result<JSONValue, PageError> {
        let pages = services.viewers.editorPages
        try await PinnedPageTests.until({ pages.tabs[key]?.provider != nil }, report: { "the metrics tab's page was never made" })
        let provider = try #require(pages.tabs[key]?.provider)
        do {
            return .success(try await provider.call(FilePageKind.editor.op("config"), params: .object([:]),
                                                    context: PageCallContext(page: FilePageKind.editor.namespace)))
        } catch let error as PageError {
            return .failure(error)
        }
    }

    /// After a failed write, a second View Metrics writes the file again and the same tab's page shows it.
    @Test func aSecondViewMetricsAfterAFailedWriteShowsTheFile() async throws {
        try await PinnedPageTests.withApp { services, _ in
            Self.bindFailingMetrics(services)
            let pane = try #require(services.daemon.store.workspaces.first?.screens.first?.panes.first)
            let (_, failed) = Self.run(services, on: pane)
            for task in failed { _ = await task.value }
            let key = try #require(Self.metricsTab(services))
            if case .success = try await Self.readPage(services, key) { Issue.record("the failed write's page read the file") }
            Self.bindMetrics(services)
            let (_, written) = Self.run(services, on: pane)
            for task in written { _ = await task.value }
            #expect(Self.metricsTab(services) == key, "a second tab opened for the metrics file")
            guard case .success(let config) = try await Self.readPage(services, key) else {
                Issue.record("the second View Metrics' page still fails")
                return
            }
            #expect(config["text"]?.stringValue?.contains("histograms") == true)
        }
    }
}
