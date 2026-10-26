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

        public var id: String
        public var kind: Kind
        public var engine: Engine?
        public var state: State
        public var visible: Bool
        /// The app-side bytes of its content (a terminal surface's estimate); nil when the app holds
        /// none it can count.
        public var appBytes: Int?
        public var processes: [ProcessRef]

        public init(id: String, kind: Kind, engine: Engine? = nil, state: State, visible: Bool, appBytes: Int? = nil,
                    processes: [ProcessRef] = []) {
            self.id = id
            self.kind = kind
            self.engine = engine
            self.state = state
            self.visible = visible
            self.appBytes = appBytes
            self.processes = processes
        }
    }

    public nonisolated struct Workspace: Sendable {
        public var id: String
        /// Some window has its view (shown or parked).
        public var mounted: Bool
        /// Some window keeps it parked (mounted, hidden).
        public var parked: Bool
        public var panes: Int
        public var terminalSurfaces: Int
        public var gpuResidentSurfaces: Int
        /// The app-side bytes attributed to its tabs (the sum of their ``Tab/appBytes``).
        public var appBytes: Int

        public init(id: String, mounted: Bool, parked: Bool, panes: Int, terminalSurfaces: Int = 0,
                    gpuResidentSurfaces: Int = 0, appBytes: Int = 0) {
            self.id = id
            self.mounted = mounted
            self.parked = parked
            self.panes = panes
            self.terminalSurfaces = terminalSurfaces
            self.gpuResidentSurfaces = gpuResidentSurfaces
            self.appBytes = appBytes
        }
    }

    public nonisolated struct Terminal: Sendable {
        /// Hidden terminal surfaces the warm set keeps.
        public var warmCapacity: Int
        /// Terminal surfaces that exist, shown or warm.
        public var surfaces: Int
        /// Surfaces that render now (on screen).
        public var gpuResidentCount: Int
        /// The estimated drawable and cell buffer bytes of the hidden surfaces that still hold them.
        public var hiddenNonvolatileIOSurfaceBytes: Int
        /// Evicted terminals' kept last frames.
        public var lastFrames: Int

        public init(warmCapacity: Int, surfaces: Int, gpuResidentCount: Int, hiddenNonvolatileIOSurfaceBytes: Int,
                    lastFrames: Int) {
            self.warmCapacity = warmCapacity
            self.surfaces = surfaces
            self.gpuResidentCount = gpuResidentCount
            self.hiddenNonvolatileIOSurfaceBytes = hiddenNonvolatileIOSurfaceBytes
            self.lastFrames = lastFrames
        }
    }

    public nonisolated struct Spare: Sendable {
        /// The pool: `new_tab` or `page_host`.
        public var pool: String
        public var processKind: MemoryDiagnosticsProcesses.Kind
        /// The spare's process; nil while it has none or the pool cannot tell.
        public var pid: Int32?

        public init(pool: String, processKind: MemoryDiagnosticsProcesses.Kind, pid: Int32?) {
            self.pool = pool
            self.processKind = processKind
            self.pid = pid
        }
    }

    /// Level, mode, budget and every consumer (``MemoryCoordinator/report(budget:)``).
    public var report: MemoryReport
    /// The kernel's level, apart from the override.
    public var kernelLevel: MemoryPressureLevel
    /// The debug override, when one is set.
    public var override: MemoryPressureLevel?
    public var history: [MemoryPressureHistory.Change]
    public var tabs: [Tab]
    public var workspaces: [Workspace]
    public var terminal: Terminal
    public var spares: [Spare]

    public init(report: MemoryReport, kernelLevel: MemoryPressureLevel, override: MemoryPressureLevel?,
                history: [MemoryPressureHistory.Change], tabs: [Tab], workspaces: [Workspace], terminal: Terminal,
                spares: [Spare]) {
        self.report = report
        self.kernelLevel = kernelLevel
        self.override = override
        self.history = history
        self.tabs = tabs
        self.workspaces = workspaces
        self.terminal = terminal
        self.spares = spares
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
    /// memory-DESIGN.md section 7, `processes[].kind`.
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

    public init(rows: [Row], rendererPIDs: [Int32: Int32] = [:]) {
        self.rows = rows
        self.rendererPIDs = rendererPIDs
    }
}
