import Foundation
import Observation
import CmuxNextTerminal

/// The R92 diagnostics of the applied Ghostty config, kept current: read
/// again on every config change (`GhosttyRuntime.configDidChange`). The
/// Settings page's Ghostty group reads it (host lists, live through
/// `cmux.settings.host.changed`); the socket's `ghostty.diagnostics`
/// computes the same list on demand.
@MainActor @Observable
final class GhosttyDiagnosticsModel {
    static let shared = GhosttyDiagnosticsModel()

    /// Nil until the first read finished (the page then shows nothing,
    /// never a false "everything applies").
    private(set) var diagnostics: [GhosttyConfigDiagnostic]?

    @ObservationIgnored private let read: @MainActor () -> GhosttyConfigDiagnosticsSnapshot?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    @ObservationIgnored private var generation = 0

    init(read: @escaping @MainActor () -> GhosttyConfigDiagnosticsSnapshot? = { GhosttyRuntime.shared.configDiagnosticsSnapshot },
         notifications: NotificationCenter = .default) {
        self.read = read
        refresh()
        observer = notifications.addObserver(forName: GhosttyRuntime.configDidChange, object: nil, queue: .main) { [weak self] _ in
            // main-proof: observer on queue: .main
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// Reads the applied config again; the keybind lines are read off the
    /// main actor, and only the newest read is kept.
    func refresh() {
        generation += 1
        let current = generation
        guard let snapshot = read() else {
            diagnostics = []
            return
        }
        // task-owner: one read per config change; a newer read supersedes it (generation).
        Task { [weak self] in
            let found = await snapshot.diagnostics()
            guard let self, self.generation == current, found != self.diagnostics else { return }
            self.diagnostics = found
        }
    }
}
