public import CmuxNextCompat

/// What `debug.memory` reads on the main actor, in one hop: the coordinator's report and the
/// app's tabs, workspaces, terminal surfaces and spares. IDs, kinds, counts and pids only: no URL,
/// title or path is copied in.
public nonisolated struct MemoryDiagnosticsSnapshot: Sendable {
    /// A process a tab draws in, as the tab knows it.
    public nonisolated enum ProcessRef: Sendable, Hashable {
        /// A WebKit WebContent process.
        case webContent(Int32)
        /// A Chromium renderer client id (`--renderer-client-id`), mapped to its helper when sampled.
        case chromiumRendererClient(Int32)
    }

    public nonisolated struct Tab: Sendable {
        public nonisolated enum Kind: String, Sendable, Encodable { case terminal, browser, agent, other }
        public nonisolated enum Engine: String, Sendable, Encodable { case cef, webkit }
        /// The tab's content phase: `live` is mounted (shown or hidden), `discarded` hibernated.
        public nonisolated enum State: String, Sendable, Encodable { case unmounted, live, discarded, restoring, crashed }

        /// The tab's store ID.
        public var key: String
        public var kind: Kind
        public var engine: Engine?
        public var state: State
        public var visible: Bool
        /// The app-side bytes of its content (a terminal surface's estimate); nil when the app holds
        /// none it can count.
        public var appBytes: Int?
        public var processes: [ProcessRef]

        public init(key: String, kind: Kind, engine: Engine? = nil, state: State, visible: Bool, appBytes: Int? = nil,
                    processes: [ProcessRef] = []) {
            self.key = key
            self.kind = kind
            self.engine = engine
            self.state = state
            self.visible = visible
            self.appBytes = appBytes
            self.processes = processes
        }
    }

    public nonisolated struct Workspace: Sendable {
        /// `mounted`: a window shows it (with `sidebar.multiView`, beside the focused one too);
        /// `parked`: a window keeps it mounted off screen; `unmounted`: no window holds its views.
        public nonisolated enum State: String, Sendable, Encodable { case mounted, parked, unmounted }

        public var id: String
        public var state: State
        public var panes: Int
        public var terminalSurfaces: Int
        /// Its terminal surfaces the surface ledger has drawing.
        public var renderingSurfaces: Int
        /// The ``Tab/key``s of its tabs; the report adds up their bytes as the workspace's.
        public var tabKeys: [String]

        public init(id: String, state: State, panes: Int, terminalSurfaces: Int = 0, renderingSurfaces: Int = 0,
                    tabKeys: [String] = []) {
            self.id = id
            self.state = state
            self.panes = panes
            self.terminalSurfaces = terminalSurfaces
            self.renderingSurfaces = renderingSurfaces
            self.tabKeys = tabKeys
        }
    }

    public nonisolated struct Terminal: Sendable {
        /// Hidden terminal surfaces the warm set keeps.
        public var warmCapacity: Int
        /// Terminal surfaces that exist, shown or warm.
        public var surfaces: Int
        /// Surfaces the surface ledger has drawing.
        public var rendering: Int
        /// Estimated non-volatile IOSurface bytes of the hidden surfaces (away, outside the keep-alive
        /// band): the two swap-chain buffers besides the volatile presented frame while GPU resident, 0
        /// once released; nil: unknown.
        public var hiddenNonvolatileIOSurfaceBytes: Int?
        /// Evicted terminals' kept last frames.
        public var lastFrames: Int

        public init(warmCapacity: Int, surfaces: Int, rendering: Int, hiddenNonvolatileIOSurfaceBytes: Int?, lastFrames: Int) {
            self.warmCapacity = warmCapacity
            self.surfaces = surfaces
            self.rendering = rendering
            self.hiddenNonvolatileIOSurfaceBytes = hiddenNonvolatileIOSurfaceBytes
            self.lastFrames = lastFrames
        }
    }

    public nonisolated struct Spare: Sendable {
        /// The pool: `new_tab`, `page_host`, or a Chromium spare window, `chromium_window` (the default
        /// profile's) or `chromium_pages_window` (the cmux pages profile's). A renderer that hosts no frame
        /// is no snapshot row: the report finds it among the sampled helpers
        /// (``MemoryDiagnosticsProcesses/rendererClientsWithFrames``).
        public var pool: String
        public var processKind: MemoryDiagnosticsProcesses.Kind
        /// The spare's process; nil while it has none or the pool cannot tell.
        public var pid: Int32?
        /// A Chromium spare's renderer client ids (its placeholder page's), mapped to the helper's pid when
        /// sampled; empty for a WebKit spare and for a placeholder with no renderer.
        public var rendererClients: [Int32]

        public init(pool: String, processKind: MemoryDiagnosticsProcesses.Kind, pid: Int32?, rendererClients: [Int32] = []) {
            self.pool = pool
            self.processKind = processKind
            self.pid = pid
            self.rendererClients = rendererClients
        }
    }

    /// Level, mode, budget and every consumer (``MemoryCoordinator/report(budget:)``).
    public var report: MemoryReport
    /// The kernel's level, apart from the override.
    public var kernelLevel: MemoryPressureLevel
    /// The debug override, when one is set.
    public var override: MemoryPressureLevel?
    /// The pressure changes and when the applied level last changed.
    public var history: MemoryPressureHistory.Snapshot
    public var tabs: [Tab]
    public var workspaces: [Workspace]
    public var terminal: Terminal
    public var spares: [Spare]
    /// The local memory histograms (``MemoryHistograms``).
    public var histograms: MemoryHistograms.Snapshot

    public init(report: MemoryReport, kernelLevel: MemoryPressureLevel, override: MemoryPressureLevel?,
                history: MemoryPressureHistory.Snapshot, tabs: [Tab], workspaces: [Workspace], terminal: Terminal,
                spares: [Spare], histograms: MemoryHistograms.Snapshot = .empty) {
        self.report = report
        self.kernelLevel = kernelLevel
        self.override = override
        self.history = history
        self.tabs = tabs
        self.workspaces = workspaces
        self.terminal = terminal
        self.spares = spares
        self.histograms = histograms
    }

    /// The WebContent processes of the tabs and spares, each once, for the sampler.
    public var webContentPIDs: [Int32] {
        var seen = Set<Int32>()
        let tabPIDs = tabs.flatMap(\.processes).compactMap { ref -> Int32? in
            if case .webContent(let pid) = ref { pid } else { nil }
        }
        let sparePIDs = spares.filter { $0.processKind == .webkitWebContent }.compactMap(\.pid)
        return (tabPIDs + sparePIDs).filter { seen.insert($0).inserted }
    }
}

/// The app's processes and their footprints, sampled off the main actor.
public nonisolated struct MemoryDiagnosticsProcesses: Sendable {
    /// `processes[].kind` (schemas/debug-memory/debug-memory.schema.json).
    public nonisolated enum Kind: String, Sendable, Encodable {
        case app
        case chromiumRenderer = "chromium_renderer"
        case chromiumGPU = "chromium_gpu"
        case chromiumUtility = "chromium_utility"
        case webkitWebContent = "webkit_webcontent"
        case other
    }

    public nonisolated struct Row: Sendable, Equatable {
        public var kind: Kind
        public var pid: Int32
        /// `phys_footprint`; nil when the process could not be read (gone, not ours).
        public var physFootprintBytes: Int?

        public init(kind: Kind, pid: Int32, physFootprintBytes: Int?) {
            self.kind = kind
            self.pid = pid
            self.physFootprintBytes = physFootprintBytes
        }
    }

    public var rows: [Row]
    /// Chromium renderer client id to its helper's pid.
    public var rendererPIDs: [Int32: Int32]
    /// The renderer client ids that host a frame of any browser Chromium holds (tabs, popups, the spare
    /// windows' placeholders, DevTools), read after the helpers were listed: a listed renderer's frame
    /// that committed before the read is in it; nil when not read (no Chromium in this process). A listed
    /// renderer outside it is a `chromium_unattributed_renderer` row in `spares`.
    public var rendererClientsWithFrames: Set<Int32>?

    public init(rows: [Row], rendererPIDs: [Int32: Int32] = [:], rendererClientsWithFrames: Set<Int32>? = nil) {
        self.rows = rows
        self.rendererPIDs = rendererPIDs
        self.rendererClientsWithFrames = rendererClientsWithFrames
    }
}
