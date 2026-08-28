import Foundation
import SwiftUI

/// One source's discovery state in the Harbor panel.
struct HarborSourceSection: Identifiable, Equatable {
    enum Status: Equatable {
        case loading
        case loaded
        case unreachable(String)
    }

    let source: HarborSource
    var status: Status
    var sessions: [HarborSession]

    var id: String {
        switch source {
        case .local: return "local"
        case .ssh(let destination): return "ssh:\(destination)"
        }
    }
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
        var hosts = hosts(defaults: defaults)
        guard !hosts.contains(destination) else { return false }
        hosts.append(destination)
        defaults.set(hosts, forKey: defaultsKey)
        return true
    }

    static func remove(_ destination: String, defaults: UserDefaults = .standard) {
        let hosts = hosts(defaults: defaults).filter { $0 != destination }
        defaults.set(hosts, forKey: defaultsKey)
    }

    /// `user@host`, `host`, or an ssh-config alias; rejects strings that
    /// would be parsed as ssh options or extra words, since the destination
    /// is passed to `ssh` as one argument after `--`.
    static func isPlausibleDestination(_ destination: String) -> Bool {
        guard !destination.isEmpty,
              !destination.hasPrefix("-"),
              destination.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              destination.rangeOfCharacter(from: CharacterSet(charactersIn: "'\"\\;|&$`")) == nil
        else { return false }
        return true
    }
}

/// Owns Harbor discovery: probes this Mac plus every saved SSH destination,
/// publishing each source's result as it lands.
@MainActor
final class HarborPanelViewModel: ObservableObject {
    @Published private(set) var sections: [HarborSourceSection] = []
    @Published private(set) var isRefreshing = false

    private var refreshGeneration = 0

    var sources: [HarborSource] {
        [.local] + HarborHostStore.hosts().map { .ssh(destination: $0) }
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let sources = sources
        let ownSessionName = TuiTerminalAttachBridge.shared.currentSessionName
        isRefreshing = true
        sections = sources.map { source in
            // Keep the previous listing visible while its rescan runs.
            let previous = sections.first { $0.source == source }
            return HarborSourceSection(
                source: source,
                status: .loading,
                sessions: previous?.sessions ?? []
            )
        }
        for source in sources {
            Task { [weak self] in
                let outcome: Result<[HarborSession], Error>
                do {
                    outcome = .success(try await HarborSessionProbe.discoverSessions(
                        source: source,
                        ownSessionName: ownSessionName
                    ))
                } catch {
                    outcome = .failure(error)
                }
                self?.applyOutcome(outcome, source: source, generation: generation)
            }
        }
        if sources.isEmpty {
            isRefreshing = false
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

    private func applyOutcome(
        _ outcome: Result<[HarborSession], Error>,
        source: HarborSource,
        generation: Int
    ) {
        guard generation == refreshGeneration,
              let index = sections.firstIndex(where: { $0.source == source }) else { return }
        switch outcome {
        case .success(let sessions):
            sections[index].sessions = sessions
            sections[index].status = .loaded
        case .failure(let error):
            sections[index].sessions = []
            sections[index].status = .unreachable(Self.shortDescription(for: error))
        }
        if !sections.contains(where: { $0.status == .loading }) {
            isRefreshing = false
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
