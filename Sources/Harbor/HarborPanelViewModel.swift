import Foundation
import SwiftUI

/// Compatibility section used by old callers while the panel moves to the
/// hierarchical snapshot model. New UI should consume `snapshots`.
struct HarborSourceSection: Identifiable, Equatable {
    enum Status: Equatable {
        case loading
        case loaded
        case unreachable(String)
    }

    let source: HarborSource
    var status: Status
    var sessions: [HarborSession]

    var id: String { source.key }
}

/// Persisted list of user-added SSH destinations Harbor scans.
enum HarborHostStore {
    static let defaultsKey = "harbor.sshHosts.v1"

    static func hosts(defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: defaultsKey) ?? []
    }

    static func add(_ rawDestination: String, defaults: UserDefaults = .standard) -> Bool {
        let destination = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleDestination(destination) else { return false }
        var stored = hosts(defaults: defaults)
        guard !stored.contains(destination) else { return false }
        stored.append(destination)
        defaults.set(stored, forKey: defaultsKey)
        return true
    }

    static func remove(_ destination: String, defaults: UserDefaults = .standard) {
        defaults.set(hosts(defaults: defaults).filter { $0 != destination }, forKey: defaultsKey)
    }

    /// Accept one ssh-config destination. Reject options and shell syntax
    /// before the value reaches either discovery or the attach command.
    static func isPlausibleDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty,
              !destination.hasPrefix("-"),
              destination.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              destination.rangeOfCharacter(from: CharacterSet(charactersIn: "'\"\\;|&$`")) == nil
        else { return false }
        return true
    }
}

/// Owns Harbor discovery. One probe runs per host and publishes each host as
/// soon as it completes. A short cancellable polling task keeps agent state and
/// newly created panes visible without rebuilding the outline on every frame.
@MainActor
final class HarborPanelViewModel: ObservableObject {
    @Published private(set) var snapshots: [HarborHostSnapshot] = []
    /// Kept for source compatibility with the first session-only panel.
    @Published private(set) var sections: [HarborSourceSection] = []
    @Published private(set) var isRefreshing = false

    private var refreshGeneration = 0
    private var pollingTask: Task<Void, Never>?

    deinit {
        pollingTask?.cancel()
    }

    var sources: [HarborHostRef] {
        var result: [HarborHostRef] = [.local]
        for destination in HarborHostStore.hosts() {
            let host = HarborHostRef.ssh(destination: destination)
            if !result.contains(host) { result.append(host) }
        }
        return result
    }

    /// Starts live discovery. Calling this more than once is harmless.
    func start() {
        guard pollingTask == nil else { return }
        refresh()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(2))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        // In-flight host probes may finish after the panel disappears. Move
        // the generation forward so their results cannot repopulate a stopped
        // model or race the next appearance's first refresh.
        refreshGeneration += 1
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let hosts = sources
        let ownSessionName = TuiTerminalAttachBridge.shared.currentSessionName
        let previous = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.host.key, $0) })
        isRefreshing = !hosts.isEmpty
        snapshots = hosts.map { host in
            var snapshot = previous[host.key] ?? HarborHostSnapshot(host: host, status: .loading, sessions: [])
            snapshot.status = .loading
            return snapshot
        }
        publishSections()

        guard !hosts.isEmpty else {
            isRefreshing = false
            return
        }

        for host in hosts {
            Task { [weak self] in
                let result: Result<[HarborSessionInfo], Error>
                do {
                    result = .success(try await HarborSessionProbe.discoverSessions(
                        host: host,
                        ownSessionName: ownSessionName
                    ))
                } catch {
                    result = .failure(error)
                }
                self?.apply(result, host: host, generation: generation)
            }
        }
    }

    func addHost(_ destination: String) -> Bool {
        guard HarborHostStore.add(destination) else { return false }
        refresh()
        return true
    }

    func removeHost(_ destination: String) {
        HarborHostStore.remove(destination)
        refresh()
    }

    private func apply(
        _ result: Result<[HarborSessionInfo], Error>,
        host: HarborHostRef,
        generation: Int
    ) {
        guard generation == refreshGeneration,
              let index = snapshots.firstIndex(where: { $0.host == host }) else { return }
        switch result {
        case .success(let sessions):
            snapshots[index].sessions = sessions
            snapshots[index].status = .loaded
        case .failure(let error):
            snapshots[index].sessions = []
            snapshots[index].status = .unreachable(Self.shortDescription(for: error))
        }
        isRefreshing = snapshots.contains { snapshot in
            if case .loading = snapshot.status { return true }
            return false
        }
        publishSections()
    }

    private func publishSections() {
        sections = snapshots.map { snapshot in
            let status: HarborSourceSection.Status
            switch snapshot.status {
            case .loading: status = .loading
            case .loaded: status = .loaded
            case .unreachable(let reason): status = .unreachable(reason)
            }
            let sessions = snapshot.sessions.map { info in
                HarborSession(
                    source: snapshot.host,
                    tool: info.tool,
                    name: info.name,
                    state: info.state,
                    detail: info.detail
                )
            }
            return HarborSourceSection(source: snapshot.host, status: status, sessions: sessions)
        }
    }

    private nonisolated static func shortDescription(for error: Error) -> String {
        if case HarborSessionProbe.ProbeError.timedOut = error {
            return String(localized: "harbor.error.timeout", defaultValue: "timed out")
        }
        if case HarborSessionProbe.ProbeError.failed(_, let stderr) = error {
            let line = stderr.split(separator: "\n").first.map(String.init) ?? ""
            return line.isEmpty
                ? String(localized: "harbor.error.probeFailed", defaultValue: "probe failed")
                : line
        }
        return String(localized: "harbor.error.probeFailed", defaultValue: "probe failed")
    }
}
