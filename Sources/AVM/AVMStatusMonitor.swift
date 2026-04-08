import Foundation
import Combine

/// Security status tier for an agent or workspace.
enum AVMSecurityStatus: String, Sendable, Comparable {
    case safe       // All agents within limits, no blocked commands
    case warning    // Resource usage approaching limits or pending approvals
    case blocked    // Agent killed/stopped or command denied

    /// Badge color hex for sidebar/tab display.
    var colorHex: String {
        switch self {
        case .safe: return "#4CAF50"       // green
        case .warning: return "#FF9800"    // amber
        case .blocked: return "#F44336"    // red
        }
    }

    /// SF Symbol icon name.
    var iconName: String {
        switch self {
        case .safe: return "shield.checkmark.fill"
        case .warning: return "exclamationmark.shield.fill"
        case .blocked: return "xmark.shield.fill"
        }
    }

    /// Human-readable label.
    var label: String {
        switch self {
        case .safe: return "Safe"
        case .warning: return "Warning"
        case .blocked: return "Blocked"
        }
    }

    static func < (lhs: AVMSecurityStatus, rhs: AVMSecurityStatus) -> Bool {
        let order: [AVMSecurityStatus] = [.safe, .warning, .blocked]
        return (order.firstIndex(of: lhs) ?? 0) < (order.firstIndex(of: rhs) ?? 0)
    }
}

/// Snapshot of AVM state at a point in time.
struct AVMStatusSnapshot: Sendable {
    let isConnected: Bool
    let agents: [AVMAgentInfo]
    let pendingApprovalCount: Int
    let proxyPort: UInt16?
    let overallStatus: AVMSecurityStatus
    let timestamp: Date

    static let disconnected = AVMStatusSnapshot(
        isConnected: false,
        agents: [],
        pendingApprovalCount: 0,
        proxyPort: nil,
        overallStatus: .safe,
        timestamp: Date()
    )
}

/// Monitors the AVM daemon and publishes status snapshots for UI consumption.
///
/// The monitor runs a background polling loop (default 5s interval) that queries avmd
/// for agent list, pending approvals, and proxy info. It publishes an `AVMStatusSnapshot`
/// that UI components (sidebar, tab badges) can observe.
@MainActor
final class AVMStatusMonitor: ObservableObject {

    static let shared = AVMStatusMonitor()

    @Published private(set) var snapshot: AVMStatusSnapshot = .disconnected
    @Published private(set) var isRunning = false

    /// Per-workspace tracked agent IDs (workspace UUID -> set of avmd agent IDs).
    @Published private(set) var workspaceAgentIds: [UUID: Set<UInt64>] = [:]

    private let client: AVMClient
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?

    init(client: AVMClient = AVMClient(), pollInterval: TimeInterval = 5) {
        self.client = client
        self.pollInterval = pollInterval
    }

    /// Start the polling loop.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(nanoseconds: UInt64((self?.pollInterval ?? 5) * 1_000_000_000))
            }
        }
    }

    /// Stop the polling loop.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isRunning = false
        snapshot = .disconnected
    }

    /// Register an agent with avmd and track it for a workspace.
    func registerAgent(name: String, pid: UInt32, workspaceId: UUID) async -> UInt64? {
        do {
            let agentId = try await client.registerAgent(name: name, pid: pid)
            var ids = workspaceAgentIds[workspaceId] ?? []
            ids.insert(agentId)
            workspaceAgentIds[workspaceId] = ids
            return agentId
        } catch {
            return nil
        }
    }

    /// Deregister an agent from avmd and untrack it.
    func deregisterAgent(id: UInt64, workspaceId: UUID) async {
        try? await client.deregisterAgent(id: id)
        workspaceAgentIds[workspaceId]?.remove(id)
        if workspaceAgentIds[workspaceId]?.isEmpty == true {
            workspaceAgentIds.removeValue(forKey: workspaceId)
        }
    }

    /// Get the security status for a specific workspace based on its tracked agents.
    func statusForWorkspace(_ workspaceId: UUID) -> AVMSecurityStatus {
        guard snapshot.isConnected else { return .safe }
        guard let agentIds = workspaceAgentIds[workspaceId], !agentIds.isEmpty else {
            return .safe
        }

        var worst: AVMSecurityStatus = .safe
        for agent in snapshot.agents where agentIds.contains(agent.id) {
            let status = agentSecurityStatus(agent)
            if status > worst { worst = status }
        }

        if snapshot.pendingApprovalCount > 0 && worst < .warning {
            worst = .warning
        }

        return worst
    }

    /// Get proxy environment variables for agent shells.
    func proxyEnvironment() async -> [String: String] {
        do {
            let info = try await client.proxyInfo()
            var env: [String: String] = [:]
            if let http = info.envHttp {
                env["HTTP_PROXY"] = http
                env["http_proxy"] = http
            }
            if let https = info.envHttps {
                env["HTTPS_PROXY"] = https
                env["https_proxy"] = https
            }
            return env
        } catch {
            return [:]
        }
    }

    /// Approve a pending command.
    func approveCommand(approvalId: UInt64) async throws {
        try await client.approveCommand(approvalId: approvalId)
    }

    /// Deny a pending command.
    func denyCommand(approvalId: UInt64) async throws {
        try await client.denyCommand(approvalId: approvalId)
    }

    // MARK: - Private

    private func poll() async {
        let reachable = await client.ping()
        guard reachable else {
            if snapshot.isConnected {
                snapshot = .disconnected
            }
            return
        }

        do {
            let agents = try await client.listAgents()
            let pending = try await client.pendingApprovals()
            let proxy = try await client.proxyInfo()

            let overall = computeOverallStatus(agents: agents, pendingCount: pending.count)

            snapshot = AVMStatusSnapshot(
                isConnected: true,
                agents: agents,
                pendingApprovalCount: pending.count,
                proxyPort: proxy.port,
                overallStatus: overall,
                timestamp: Date()
            )
        } catch {
            snapshot = .disconnected
        }
    }

    private func computeOverallStatus(agents: [AVMAgentInfo], pendingCount: Int) -> AVMSecurityStatus {
        var worst: AVMSecurityStatus = .safe

        for agent in agents {
            let status = agentSecurityStatus(agent)
            if status > worst { worst = status }
        }

        if pendingCount > 0 && worst < .warning {
            worst = .warning
        }

        return worst
    }

    private func agentSecurityStatus(_ agent: AVMAgentInfo) -> AVMSecurityStatus {
        // Check RSS usage — warning at 1GB, blocked at 2GB (default policy limits)
        if let rss = agent.rssBytes {
            if rss > 2 * 1024 * 1024 * 1024 { return .blocked }
            if rss > 1024 * 1024 * 1024 { return .warning }
        }
        // Check CPU usage — warning at 1800s (30min), blocked at 3600s (1hr default)
        if let cpu = agent.cpuSecs {
            if cpu > 3600 { return .blocked }
            if cpu > 1800 { return .warning }
        }
        return .safe
    }
}
