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
    /// Keep refresh fan-out bounded even when a damaged defaults domain has
    /// been restored from another machine.
    static let maxHosts = 32
    static let maxDestinationBytes = 1024

    static func hosts(defaults: UserDefaults = .standard) -> [String] {
        var seen = Set<String>()
        return (defaults.stringArray(forKey: defaultsKey) ?? []).filter { destination in
            isPlausibleDestination(destination)
                && seen.insert(destination).inserted
        }.prefix(maxHosts).map { $0 }
    }

    static func add(_ rawDestination: String, defaults: UserDefaults = .standard) -> Bool {
        let destination = rawDestination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPlausibleDestination(destination) else { return false }
        var hosts = hosts(defaults: defaults)
        guard hosts.count < maxHosts, !hosts.contains(destination) else { return false }
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
              destination.utf8.count <= maxDestinationBytes,
              !destination.hasPrefix("-"),
              destination.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              destination.rangeOfCharacter(from: .controlCharacters) == nil,
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
    private var refreshTask: Task<Void, Never>?
    private static let maxConcurrentProbes = 4

    var sources: [HarborSource] {
        [.local] + HarborHostStore.hosts().map { .ssh(destination: $0) }
    }

    func refresh() {
        refreshTask?.cancel()
        refreshTask = nil
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
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.runRefresh(
                sources: sources,
                ownSessionName: ownSessionName,
                generation: generation
            )
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

    private func runRefresh(
        sources: [HarborSource],
        ownSessionName: String?,
        generation: Int
    ) async {
        struct ProbeOutcome: Sendable {
            let source: HarborSource
            let result: Result<[HarborSession], String>
        }

        await withTaskGroup(of: ProbeOutcome.self) { group in
            var pending = sources.makeIterator()
            for _ in 0..<Self.maxConcurrentProbes {
                guard let source = pending.next() else { break }
                group.addTask {
                    do {
                        return ProbeOutcome(
                            source: source,
                            result: .success(try await HarborSessionProbe.discoverSessions(
                                source: source,
                                ownSessionName: ownSessionName
                            ))
                        )
                    } catch {
                        return ProbeOutcome(
                            source: source,
                            result: .failure(Self.shortDescription(for: error))
                        )
                    }
                }
            }
            while let outcome = await group.next() {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    return
                }
                applyOutcome(outcome.result, source: outcome.source, generation: generation)
                if let source = pending.next() {
                    group.addTask {
                        do {
                            return ProbeOutcome(
                                source: source,
                                result: .success(try await HarborSessionProbe.discoverSessions(
                                    source: source,
                                    ownSessionName: ownSessionName
                                ))
                            )
                        } catch {
                            return ProbeOutcome(
                                source: source,
                                result: .failure(Self.shortDescription(for: error))
                            )
                        }
                    }
                }
            }
        }
        guard !Task.isCancelled, generation == refreshGeneration else { return }
        isRefreshing = false
        refreshTask = nil
    }

    private func applyOutcome(
        _ outcome: Result<[HarborSession], String>,
        source: HarborSource,
        generation: Int
    ) {
        guard generation == refreshGeneration,
              let index = sections.firstIndex(where: { $0.source == source }) else { return }
        switch outcome {
        case .success(let sessions):
            sections[index].sessions = sessions
            sections[index].status = .loaded
        case .failure(let description):
            sections[index].sessions = []
            sections[index].status = .unreachable(description)
        }
        if !sections.contains(where: { $0.status == .loading }) {
            isRefreshing = false
        }
    }

    private nonisolated static func shortDescription(for error: Error) -> String {
        if case HarborSessionProbe.ProbeError.outputTooLarge = error {
            return String(localized: "harbor.error.probeTooLarge", defaultValue: "probe output was too large")
        }
        if case HarborSessionProbe.ProbeError.timedOut = error {
            return String(localized: "harbor.error.timeout", defaultValue: "timed out")
        }
        if case HarborSessionProbe.ProbeError.failed = error {
            return String(localized: "harbor.error.probeFailed", defaultValue: "probe failed")
        }
        return String(localized: "harbor.error.probeFailed", defaultValue: "probe failed")
    }
}
