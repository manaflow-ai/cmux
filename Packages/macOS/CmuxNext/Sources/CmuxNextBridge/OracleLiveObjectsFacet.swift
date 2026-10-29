#if DEBUG || CMUX_BENCH_HOOKS
public import CmuxNextDaemon
public import CmuxNextOracle

/// The oracle's `liveObjects` facet (schemas/oracle/snapshot-v1.schema.json `liveObjects`): how
/// many of each runtime object the app holds now, read from the registries that own them. Invariant I18 compares
/// the counts after a case's teardown with the fixture's before its first step; a count that stays higher is a
/// leak (a tab whose page or surface outlived its close).
///
/// Blink's leak detector does the same: web tests read `InstanceCounters` (documents, frames, nodes, layout
/// objects) after the test and compare them with the counts before it
/// (third_party/blink/renderer/core/testing/internals.cc, third_party/blink/renderer/platform/instrumentation/
/// instance_counters.h). Here the counts come from the owners' own tables, so the facet adds no counter, no
/// observer and no work while no snapshot asks for it.
public nonisolated struct OracleLiveObjectsFacet: OracleFacetProvider {
    /// The counts now.
    public nonisolated struct Reading: Sendable, Hashable {
        /// Workspace models the daemon stores mirror, over every machine.
        public var workspaceModels: Int
        /// Chromium browsers alive in this process (0 while Chromium was never built).
        public var cefBrowsers: Int
        /// Browser page views the tab content cache holds, of every engine.
        public var pageViews: Int
        /// Terminal surfaces the tab content cache holds.
        public var terminals: Int
        /// Live terminals whose holder runs: distinct terminals of the stores' live terminal tabs.
        public var holders: Int
        /// Observations armed now (`ObservationLedger`, every owner).
        public var subscriptions: Int
        /// Deadlines waiting on the main thread's wake-up queue (`MainWakeUpQueue.count`).
        public var tasks: Int

        public init(workspaceModels: Int, cefBrowsers: Int, pageViews: Int, terminals: Int, holders: Int,
                    subscriptions: Int, tasks: Int) {
            self.workspaceModels = workspaceModels
            self.cefBrowsers = cefBrowsers
            self.pageViews = pageViews
            self.terminals = terminals
            self.holders = holders
            self.subscriptions = subscriptions
            self.tasks = tasks
        }

        /// The counts with the workspace models and holders of `stores` (``storeCounts(_:)``).
        @MainActor
        public init(stores: [DaemonStore], cefBrowsers: Int, pageViews: Int, terminals: Int, subscriptions: Int, tasks: Int) {
            let models = Self.storeCounts(stores)
            self.init(workspaceModels: models.workspaceModels, cefBrowsers: cefBrowsers, pageViews: pageViews,
                      terminals: terminals, holders: models.holders, subscriptions: subscriptions, tasks: tasks)
        }

        public var value: OracleValue {
            [
                "workspaceModels": OracleValue(workspaceModels),
                "cefBrowsers": OracleValue(cefBrowsers),
                "pageViews": OracleValue(pageViews),
                "terminals": OracleValue(terminals),
                "holders": OracleValue(holders),
                "subscriptions": OracleValue(subscriptions),
                "tasks": OracleValue(tasks),
            ]
        }

        /// The workspace models and holders of `stores`: each store's workspaces, and the distinct terminals of
        /// its terminal tabs that have not ended. A provisional workspace is the app's overlay, not a model yet.
        @MainActor
        public static func storeCounts(_ stores: [DaemonStore]) -> (workspaceModels: Int, holders: Int) {
            var workspaceModels = 0
            var holders = 0
            for store in stores {
                var terminals: Set<TerminalID> = []
                for workspace in store.workspaces where !workspace.isProvisional {
                    workspaceModels += 1
                    for screen in workspace.screens {
                        for pane in screen.panes {
                            for tab in pane.tabs where tab.kind == .pty && !tab.dead {
                                if let terminal = tab.terminalID { terminals.insert(terminal) }
                            }
                        }
                    }
                }
                holders += terminals.count
            }
            return (workspaceModels, holders)
        }
    }

    public var facet: OracleFacet { .liveObjects }
    public let capture: OracleFacetCapture

    /// - Parameter read: The counts now, read in the snapshot's main-actor turn; nil while no daemon tree is loaded
    ///   (the models are not there yet), which answers not-comparable.
    public init(read: @escaping @MainActor @Sendable () -> Reading?) {
        capture = .mainActor { () throws(OracleFacetError) -> OracleValue in
            guard let reading = read() else {
                return .notComparable(reason: "no daemon tree is loaded, so the models are not there yet",
                                      task: OracleFacet.liveObjects.task)
            }
            return reading.value
        }
    }
}
#endif
