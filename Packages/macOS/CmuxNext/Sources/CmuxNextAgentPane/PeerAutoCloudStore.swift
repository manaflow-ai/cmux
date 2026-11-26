public import CmuxNextSettings
import Foundation
public import Observation

/// Settings > Machines' AutoCloud line on each remote machine (RFD 0172): what each acpmux peer last
/// reported as `health.autoCloud`, from this Mac's daemon (`_acpmux/peers`, answered from what it
/// holds, so no machine is asked). Read when the Machines rows are drawn, at most once a minute (no
/// timer). Read-only: only the machine itself enrolls (`_acpmux/autocloud_enroll` there).
@MainActor
@Observable
public final class PeerAutoCloudStore {
    /// Each peer's report, by every key it can be found under (its acpmux name and its `ssh://` host).
    public private(set) var reports: [String: AcpmuxPeerList.AutoCloud] = [:]
    @ObservationIgnored private var lastRead: ContinuousClock.Instant?
    @ObservationIgnored private var reading: Task<Void, Never>?
    static let refreshAfter: Duration = .seconds(60)

    public init() {}

    /// The report for the machine reached at `host` (an SSH destination's host, or a peer name),
    /// starting a read of `socket` (this Mac's acpmux socket now; nil while it has none) when the last
    /// is a minute old. Nil until a peer by that host reports one.
    public func report(host: String, socket: String?) -> AcpmuxPeerList.AutoCloud? {
        refreshIfStale(socket: socket)
        return reports[host.lowercased()]
    }

    private func refreshIfStale(socket: String?) {
        guard reading == nil, lastRead.map({ ContinuousClock.now - $0 >= Self.refreshAfter }) ?? true,
              let socket else { return }
        lastRead = .now
        reading = Task { [weak self] in
            let peers = (try? await AcpmuxPeerList(socketPath: socket).peers()) ?? []
            guard let self else { return }
            self.reading = nil
            let next = Self.index(peers)
            if next != self.reports { self.reports = next }
        }
    }

    /// Peers' reports keyed by lowercased name and by the host of an `ssh://[user@]host[:port]` url.
    nonisolated public static func index(_ peers: [AcpmuxPeerList.Peer]) -> [String: AcpmuxPeerList.AutoCloud] {
        var out: [String: AcpmuxPeerList.AutoCloud] = [:]
        for peer in peers {
            guard let report = peer.autoCloud else { continue }
            out[peer.name.lowercased()] = report
            if let url = peer.url.flatMap(URL.init(string:)), url.scheme == "ssh", let host = url.host, !host.isEmpty {
                out[host.lowercased()] = report
            }
        }
        return out
    }

    /// `row` (a Settings > Machines row) with its `autocloud` member when `host` (its SSH destination's
    /// host; nil for a Cloud machine) is a peer that reports `health.autoCloud`; else `row` as it is.
    public func row(_ row: JSONValue, host: String?, socket: String?) -> JSONValue {
        guard case .object(var members) = row, let host, let report = report(host: host, socket: socket) else { return row }
        members["autocloud"] = Self.rowJSON(report)
        return .object(members)
    }

    /// The row's `autocloud` member (`MachineAutoCloud` in webviews/src/pages/settings/ops.ts).
    nonisolated public static func rowJSON(_ report: AcpmuxPeerList.AutoCloud) -> JSONValue {
        let hours: JSONValue = report.hours.map { ["from": .number(Double($0.from)), "to": .number(Double($0.to))] } ?? .null
        var row: [String: JSONValue] = [
            "on": .bool(report.enrolled), "error": .null, "accepting": .bool(report.accepting),
            "policy": ["teams": .array(report.teams.map(JSONValue.string)), "agents": .array(report.agents.map(JSONValue.string)), "hours": hours],
            "caps": .array(report.caps.map(JSONValue.string)),
        ]
        if let idle = report.ownerIdle { row["owner_idle"] = .bool(idle) }
        return .object(row)
    }
}
