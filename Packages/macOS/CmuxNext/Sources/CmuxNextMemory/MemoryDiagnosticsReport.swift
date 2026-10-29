public import CmuxNextCompat
public import Foundation

/// The `debug.memory` answer, with the keys of schemas/debug-memory/debug-memory.schema.json: byte
/// counts as integers, an unknown count as `null`, never 0, and no URL, title or path: an ID or a
/// name that is not a plain token (letters, digits, `-`, `_`, `.`, `:`, at most 64 bytes) is
/// written as ``redacted``.
///
/// `mode`, `budget` and `consumers` are ``MemoryReport``'s own encoding, so a reader of
/// `memory-report.py` and of `debug.memory` sees one schema; the other sections are the app's rows.
///
/// The analog of Chrome's `chrome://memory-internals`
/// (`chrome/browser/ui/webui/memory_internals/memory_internals_ui.cc`) over the memory-infra dump
/// (`base/trace_event/memory_dump_manager.h`). A process two tabs share (a WebKit process group, a
/// shared renderer) is in neither tab's bytes, as Chrome's Task Manager keeps a shared renderer's
/// memory on one row (`chrome/browser/task_manager/providers/web_contents/`); a workspace's bytes
/// are its tabs' known bytes, and `unknown_tabs` counts the tabs left out.
public nonisolated struct MemoryDiagnosticsReport: Sendable {
    /// The placeholder for an ID or name that could carry a URL, title or path.
    public static let redacted = "redacted"

    public let snapshot: MemoryDiagnosticsSnapshot
    public let processes: MemoryDiagnosticsProcesses

    public init(snapshot: MemoryDiagnosticsSnapshot, processes: MemoryDiagnosticsProcesses) {
        self.snapshot = snapshot
        self.processes = processes
    }

    /// The report as UTF-8 JSON.
    ///
    /// - Returns: The JSON object of schemas/debug-memory/debug-memory.schema.json.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    /// `value` when it is a plain token, else ``redacted``.
    public func opaque(_ value: String) -> String { Self.opaqueToken(value) }

    /// `value` when it is a plain token (at most 64 of `A-Z a-z 0-9 - _ . :`), else ``redacted``: the
    /// one redaction of every release memory diagnostic (`debug.memory`, `debug.discards`), so an ID
    /// or a name that carries a URL, a title or a path never leaves the app.
    public static func opaqueToken(_ value: String) -> String {
        let isToken = !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy(isTokenByte)
        return isToken ? value : redacted
    }

    private static func isTokenByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "a") ... UInt8(ascii: "z"), UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: ":"):
            true
        default:
            false
        }
    }

    // MARK: Rows

    private var body: Body {
        let report = snapshot.report
        let footprints = Dictionary(processes.rows.map { ($0.pid, $0.physFootprintBytes) }, uniquingKeysWith: { first, _ in first })
        let tabs = tabRows(footprints: footprints)
        var bytesByKey: [String: Int?] = [:]
        for (tab, row) in zip(snapshot.tabs, tabs) { bytesByKey[tab.key] = row.bytes.value }
        return Body(
            pressure: Pressure(level: report.level, kernelLevel: snapshot.kernelLevel, override: Count(snapshot.override),
                               sinceMs: snapshot.history.levelSinceMilliseconds),
            mode: report.mode,
            budget: report.budget,
            consumers: report.consumers.map { consumer in
                MemoryReport.Consumer(name: opaque(consumer.name), traits: consumer.traits, limit: consumer.limit,
                                      footprintBytes: consumer.footprintBytes, volatileBytes: consumer.volatileBytes,
                                      entries: consumer.entries)
            },
            processes: processes.rows.map { ProcessRow(kind: $0.kind, pid: $0.pid, physFootprintBytes: Count($0.physFootprintBytes)) },
            tabs: tabs,
            workspaces: snapshot.workspaces.map { workspace in
                let bytes = workspace.tabKeys.map { bytesByKey[$0] ?? nil }
                return WorkspaceRow(id: opaque(workspace.id), state: workspace.state, panes: workspace.panes,
                                    terminalSurfaces: workspace.terminalSurfaces, renderingSurfaces: workspace.renderingSurfaces,
                                    tabs: workspace.tabKeys.count, bytes: bytes.compactMap { $0 }.reduce(0, +),
                                    unknownTabs: bytes.filter { $0 == nil }.count)
            },
            terminal: TerminalRow(snapshot.terminal),
            spares: spareRows(footprints: footprints),
            pressureHistory: snapshot.history.changes.map {
                HistoryRow(atMs: $0.atMilliseconds, level: $0.level, kernelLevel: $0.kernelLevel, override: Count($0.override),
                           source: $0.source)
            },
            histograms: snapshot.histograms
        )
    }

    /// The snapshot's spares, a Chromium spare window's pid from its placeholder's renderer client, then
    /// one `chromium_unattributed_renderer` row per sampled renderer helper that hosts no frame of any
    /// browser, by pid. No such row when the sample did not read the frames.
    private func spareRows(footprints: [Int32: Int?]) -> [SpareRow] {
        func row(_ pool: String, _ kind: MemoryDiagnosticsProcesses.Kind, _ pid: Int32?) -> SpareRow {
            SpareRow(pool: opaque(pool), processKind: kind, pid: Count(pid), bytes: Count(pid.flatMap { footprints[$0] ?? nil }))
        }
        var rows = snapshot.spares.map { spare in
            row(spare.pool, spare.processKind, spare.pid ?? spare.rendererClients.lazy.compactMap { processes.rendererPIDs[$0] }.first)
        }
        guard let withFrames = processes.rendererClientsWithFrames else { return rows }
        let claimed = withFrames.union(snapshot.spares.flatMap(\.rendererClients))
        let unattributed = processes.rendererPIDs.filter { !claimed.contains($0.key) }.values.sorted()
        rows += unattributed.map { row(Self.chromiumUnattributedPool, .chromiumRenderer, $0) }
        return rows
    }

    /// The pool of a Chromium renderer that hosts no frame of any browser: Chromium's own spare
    /// (`SpareRenderProcessHostManager`), and also a renderer whose first navigation has not committed
    /// yet or one that holds only workers or back/forward-cached pages. The fork exposes no read of the
    /// spare's id, which Chrome's Task Manager matches on
    /// (chrome/browser/task_manager/providers/spare_render_process_host_task_provider.cc), so the row
    /// does not name the spare: at Home idle the count of these rows is an upper bound on Chromium's spares.
    public static let chromiumUnattributedPool = "chromium_unattributed_renderer"

    /// Each tab with the pids it draws in, and its bytes when every one of them is its own.
    private func tabRows(footprints: [Int32: Int?]) -> [TabRow] {
        let pidsByTab = snapshot.tabs.map { tab in
            tab.processes.compactMap { ref -> Int32? in
                switch ref {
                case .webContent(let pid): pid
                case .chromiumRendererClient(let client): processes.rendererPIDs[client]
                }
            }
        }
        var users: [Int32: Int] = [:]
        for pid in pidsByTab.flatMap({ Set($0) }) { users[pid, default: 0] += 1 }
        return zip(snapshot.tabs, pidsByTab).map { tab, pids in
            var bytes = tab.appBytes
            if !pids.isEmpty {
                let sampled = pids.compactMap { footprints[$0] ?? nil }
                let own = pids.allSatisfy { users[$0] == 1 }
                bytes = own && sampled.count == pids.count ? sampled.reduce(tab.appBytes ?? 0, +) : nil
            }
            return TabRow(key: opaque(tab.key), kind: tab.kind, engine: Count(tab.engine), state: tab.state,
                          visible: tab.visible, pids: pids, bytes: Count(bytes))
        }
    }

    /// A value that is written as `null` when absent (a synthesized `Encodable` would leave the key out).
    private nonisolated struct Count<Value: Encodable & Sendable>: Encodable, Sendable {
        let value: Value?
        init(_ value: Value?) { self.value = value }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            if let value { try container.encode(value) } else { try container.encodeNil() }
        }
    }

    private nonisolated struct Body: Encodable, Sendable {
        let pressure: Pressure
        let mode: MemorySaverMode
        let budget: SubsystemBudget
        let consumers: [MemoryReport.Consumer]
        let processes: [ProcessRow]
        let tabs: [TabRow]
        let workspaces: [WorkspaceRow]
        let terminal: TerminalRow
        let spares: [SpareRow]
        let pressureHistory: [HistoryRow]
        let histograms: MemoryHistograms.Snapshot

        enum CodingKeys: String, CodingKey {
            case pressure, mode, budget, consumers, processes, tabs, workspaces, terminal, spares, histograms
            case pressureHistory = "pressure_history"
        }
    }

    private nonisolated struct Pressure: Encodable, Sendable {
        let level: MemoryPressureLevel
        let kernelLevel: MemoryPressureLevel
        let override: Count<MemoryPressureLevel>
        let sinceMs: Int

        enum CodingKeys: String, CodingKey {
            case level, override
            case kernelLevel = "kernel_level"
            case sinceMs = "since_ms"
        }
    }

    private nonisolated struct ProcessRow: Encodable, Sendable {
        let kind: MemoryDiagnosticsProcesses.Kind
        let pid: Int32
        let physFootprintBytes: Count<Int>

        enum CodingKeys: String, CodingKey {
            case kind, pid
            case physFootprintBytes = "phys_footprint_bytes"
        }
    }

    private nonisolated struct TabRow: Encodable, Sendable {
        let key: String
        let kind: MemoryDiagnosticsSnapshot.Tab.Kind
        let engine: Count<MemoryDiagnosticsSnapshot.Tab.Engine>
        let state: MemoryDiagnosticsSnapshot.Tab.State
        let visible: Bool
        let pids: [Int32]
        let bytes: Count<Int>
    }

    private nonisolated struct WorkspaceRow: Encodable, Sendable {
        let id: String
        let state: MemoryDiagnosticsSnapshot.Workspace.State
        let panes: Int
        let terminalSurfaces: Int
        let renderingSurfaces: Int
        let tabs: Int
        /// The sum of its tabs' known bytes.
        let bytes: Int
        /// Its tabs whose bytes are unknown (a shared or unsampled process, no content), not in `bytes`.
        let unknownTabs: Int

        enum CodingKeys: String, CodingKey {
            case id, state, panes, tabs, bytes
            case terminalSurfaces = "terminal_surfaces"
            case renderingSurfaces = "rendering_surfaces"
            case unknownTabs = "unknown_tabs"
        }
    }

    private nonisolated struct TerminalRow: Encodable, Sendable {
        let warmCapacity: Int
        let surfaces: Int
        let rendering: Int
        let hiddenNonvolatileIOSurfaceBytes: Count<Int>
        let lastFrames: Int

        init(_ terminal: MemoryDiagnosticsSnapshot.Terminal) {
            warmCapacity = terminal.warmCapacity
            surfaces = terminal.surfaces
            rendering = terminal.rendering
            hiddenNonvolatileIOSurfaceBytes = Count(terminal.hiddenNonvolatileIOSurfaceBytes)
            lastFrames = terminal.lastFrames
        }

        enum CodingKeys: String, CodingKey {
            case surfaces, rendering
            case warmCapacity = "warm_capacity"
            case hiddenNonvolatileIOSurfaceBytes = "hidden_nonvolatile_iosurface_bytes"
            case lastFrames = "last_frames"
        }
    }

    private nonisolated struct SpareRow: Encodable, Sendable {
        let pool: String
        let processKind: MemoryDiagnosticsProcesses.Kind
        let pid: Count<Int32>
        let bytes: Count<Int>

        enum CodingKeys: String, CodingKey {
            case pool, pid, bytes
            case processKind = "process_kind"
        }
    }

    private nonisolated struct HistoryRow: Encodable, Sendable {
        let atMs: Int
        let level: MemoryPressureLevel
        let kernelLevel: MemoryPressureLevel
        let override: Count<MemoryPressureLevel>
        let source: MemoryPressureHistory.Source

        enum CodingKeys: String, CodingKey {
            case level, override, source
            case atMs = "at_ms"
            case kernelLevel = "kernel_level"
        }
    }
}
