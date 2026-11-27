import Foundation
import Observation
import CmuxNextTerminal
import CmuxNextCompat

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
    /// The theme colors the user's Ghostty files set themselves, which no theme can change (the
    /// Theme section's notice). Read with the config, so current at once.
    private(set) var colorOverrides: [GhosttyColorOverride] = []

    @ObservationIgnored private let read: @MainActor () -> GhosttyConfigDiagnosticsSnapshot?
    @ObservationIgnored private var observer: MainActorObservation?
    @ObservationIgnored private var generation = 0

    init(read: @escaping @MainActor () -> GhosttyConfigDiagnosticsSnapshot? = { GhosttyRuntime.shared.configDiagnosticsSnapshot },
         notifications: NotificationCenter = .default) {
        self.read = read
        refresh()
        observer = MainActorObservation(GhosttyRuntime.configDidChange, center: notifications) { [weak self] in
            self?.refresh()
        }
    }

    /// Reads the applied config again; the keybind lines are read off the
    /// main actor, and only the newest read is kept.
    func refresh() {
        generation += 1
        let current = generation
        guard let snapshot = read() else {
            diagnostics = []
            colorOverrides = []
            return
        }
        if snapshot.colorOverrides != colorOverrides { colorOverrides = snapshot.colorOverrides }
        // task-owner: one read per config change; a newer read supersedes it (generation).
        Task { [weak self] in
            let found = await snapshot.diagnostics()
            guard let self, self.generation == current, found != self.diagnostics else { return }
            self.diagnostics = found
        }
    }
}
