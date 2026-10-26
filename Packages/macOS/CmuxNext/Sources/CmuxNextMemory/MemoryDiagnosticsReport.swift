public import CmuxNextCompat
public import Foundation

/// The `debug.memory` answer (plans/cmux-next/memory-DESIGN.md section 7): snake_case keys, byte
/// counts as integers, an unknown count as `null`, never 0, and no URL, title or path: an ID or a
/// name that is not a plain token (letters, digits, `-`, `_`, `.`, `:`, at most 64 bytes) is
/// written as ``redacted``.
///
/// The analog of Chrome's `chrome://memory-internals`
/// (`chrome/browser/ui/webui/memory_internals/memory_internals_ui.cc`) over the memory-infra dump
/// (`base/trace_event/memory_dump_manager.h`). A process two tabs share (a WebKit process group, a
/// shared renderer) is in neither tab's bytes, as Chrome's Task Manager keeps a shared renderer's
/// memory on one row (`chrome/browser/task_manager/providers/web_contents/`).
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
    /// - Returns: The JSON object of memory-DESIGN.md section 7.
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(body)
    }

    /// `value` when it is a plain token, else ``redacted``.
    public func opaque(_ value: String) -> String {
        let isToken = !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy(Self.isTokenByte)
        return isToken ? value : Self.redacted
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

    // MARK: Rows (property names become the snake_case keys)

    private var body: Body {
        let report = snapshot.report
        let footprints = Dictionary(processes.rows.map { ($0.pid, $0.physFootprintBytes) }, uniquingKeysWith: { first, _ in first })
        return Body(
            pressure: Pressure(level: report.level, kernelLevel: snapshot.kernelLevel, override: Count(snapshot.override),
                               sinceMs: Count(snapshot.history.last?.atMilliseconds)),
            mode: report.mode,
            budget: Budget(report.budget),
            consumers: report.consumers.map { Consumer($0, name: opaque($0.name)) },
            processes: processes.rows.map { ProcessRow(kind: $0.kind, pid: $0.pid, physFootprintBytes: Count($0.physFootprintBytes)) },
            tabs: tabRows(footprints: footprints),
            workspaces: snapshot.workspaces.map { WorkspaceRow($0, id: opaque($0.id)) },
            terminal: TerminalRow(snapshot.terminal),
            spares: snapshot.spares.map { spare in
                SpareRow(pool: opaque(spare.pool), processKind: spare.processKind, pid: Count(spare.pid),
                         bytes: Count(spare.pid.flatMap { footprints[$0] ?? nil }))
            },
            pressureHistory: snapshot.history.map { HistoryRow(atMs: $0.atMilliseconds, level: $0.level, source: $0.source) }
        )
    }

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
            return TabRow(id: opaque(tab.id), kind: tab.kind, engine: Count(tab.engine), state: tab.state,
                          visible: tab.visible, pids: pids, footprintBytes: Count(bytes))
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
        let budget: Budget
        let consumers: [Consumer]
        let processes: [ProcessRow]
        let tabs: [TabRow]
        let workspaces: [WorkspaceRow]
        let terminal: TerminalRow
        let spares: [SpareRow]
        let pressureHistory: [HistoryRow]
    }

    private nonisolated struct Pressure: Encodable, Sendable {
        let level: MemoryPressureLevel
        let kernelLevel: MemoryPressureLevel
        let override: Count<MemoryPressureLevel>
        let sinceMs: Count<Int>
    }

    private nonisolated struct Budget: Encodable, Sendable {
        let physicalBytes: Int
        let gpuResidentAvailable: Bool
        let chromiumRendererLimit: Int
        let warmTerminalSurfaces: Int
        let parkedWorkspaces: Int
        let parkedIdleTimeoutS: Int
        let imageCacheBytes: Int
        let homeRenderBitmapBytes: Int
        let hibernationSnapshotBytes: Int
        let liveHiddenAgentPages: Int
        let liveHiddenInternalPages: Int
        let kittyImageBytesPerSurface: Int
        let webProcessPagesPerGroup: Int

        init(_ budget: SubsystemBudget) {
            physicalBytes = budget.physicalMiB << 20
            gpuResidentAvailable = budget.gpuResidentAvailable
            chromiumRendererLimit = budget.chromiumRendererLimit
            warmTerminalSurfaces = budget.warmTerminalSurfaces
            parkedWorkspaces = budget.parkedWorkspaces
            parkedIdleTimeoutS = Int(budget.parkedIdleTimeout.components.seconds)
            imageCacheBytes = budget.imageCacheBytes
            homeRenderBitmapBytes = budget.homeRenderBitmapBytes
            hibernationSnapshotBytes = budget.hibernationSnapshotBytes
            liveHiddenAgentPages = budget.liveHiddenAgentPages
            liveHiddenInternalPages = budget.liveHiddenInternalPages
            kittyImageBytesPerSurface = budget.kittyImageBytesPerSurface
            webProcessPagesPerGroup = budget.webProcessPagesPerGroup
        }
    }

    private nonisolated struct Traits: Encodable, Sendable {
        let estimatedUsage: String
        let dataAccess: String
        let retention: String
        let recreateCost: String
        let releaseCpuCost: String
        let isStateful: Bool
        let supportsMemoryLimit: Bool

        init(_ traits: MemoryConsumerTraits) {
            estimatedUsage = Self.snakeCase(traits.estimatedUsage.rawValue)
            dataAccess = Self.snakeCase(traits.dataAccess.rawValue)
            retention = Self.snakeCase(traits.retention.rawValue)
            recreateCost = Self.snakeCase(traits.recreateCost.rawValue)
            releaseCpuCost = Self.snakeCase(traits.releaseCPUCost.rawValue)
            isStateful = traits.isStateful
            supportsMemoryLimit = traits.supportsMemoryLimit
        }

        /// `readsAndWritesDisk` to `reads_and_writes_disk`.
        private static func snakeCase(_ name: String) -> String {
            var out = ""
            for character in name {
                if character.isUppercase {
                    out += "_" + character.lowercased()
                } else {
                    out.append(character)
                }
            }
            return out
        }
    }

    private nonisolated struct Consumer: Encodable, Sendable {
        let name: String
        let traits: Traits
        let managed: Bool
        let limitPercent: Int
        let footprintBytes: Count<Int>
        let volatileBytes: Count<Int>
        let entries: Count<Int>

        init(_ consumer: MemoryReport.Consumer, name: String) {
            self.name = name
            traits = Traits(consumer.traits)
            managed = consumer.traits.isManaged
            limitPercent = consumer.limit.percent
            footprintBytes = Count(consumer.footprintBytes)
            volatileBytes = Count(consumer.volatileBytes)
            entries = Count(consumer.entries)
        }
    }

    private nonisolated struct ProcessRow: Encodable, Sendable {
        let kind: MemoryDiagnosticsProcesses.Kind
        let pid: Int32
        let physFootprintBytes: Count<Int>
    }

    private nonisolated struct TabRow: Encodable, Sendable {
        let id: String
        let kind: MemoryDiagnosticsSnapshot.Tab.Kind
        let engine: Count<MemoryDiagnosticsSnapshot.Tab.Engine>
        let state: MemoryDiagnosticsSnapshot.Tab.State
        let visible: Bool
        let pids: [Int32]
        let footprintBytes: Count<Int>
    }

    private nonisolated struct WorkspaceRow: Encodable, Sendable {
        let id: String
        let mounted: Bool
        let parked: Bool
        let panes: Int
        let terminalSurfaces: Int
        let gpuResidentSurfaces: Int
        let appBytes: Int

        init(_ workspace: MemoryDiagnosticsSnapshot.Workspace, id: String) {
            self.id = id
            mounted = workspace.mounted
            parked = workspace.parked
            panes = workspace.panes
            terminalSurfaces = workspace.terminalSurfaces
            gpuResidentSurfaces = workspace.gpuResidentSurfaces
            appBytes = workspace.appBytes
        }
    }

    private nonisolated struct TerminalRow: Encodable, Sendable {
        let warmCapacity: Int
        let warmCount: Int
        let gpuResidentCount: Int
        // The design's key is `hidden_nonvolatile_iosurface_bytes` (one word, as Apple writes IOSurface).
        let hiddenNonvolatileIosurfaceBytes: Int
        let lastFrames: Int

        init(_ terminal: MemoryDiagnosticsSnapshot.Terminal) {
            warmCapacity = terminal.warmCapacity
            warmCount = terminal.surfaces - terminal.gpuResidentCount
            gpuResidentCount = terminal.gpuResidentCount
            hiddenNonvolatileIosurfaceBytes = terminal.hiddenNonvolatileIOSurfaceBytes
            lastFrames = terminal.lastFrames
        }
    }

    private nonisolated struct SpareRow: Encodable, Sendable {
        let pool: String
        let processKind: MemoryDiagnosticsProcesses.Kind
        let pid: Count<Int32>
        let bytes: Count<Int>
    }

    private nonisolated struct HistoryRow: Encodable, Sendable {
        let atMs: Int
        let level: MemoryPressureLevel
        let source: MemoryPressureHistory.Source
    }
}
