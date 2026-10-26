import Foundation
import Observation
import CmuxNextTerminal

/// The R92 diagnostics of the applied Ghostty config, kept current: read
/// again on every config change (`GhosttyRuntime.addConfigChangeHandler`). The
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
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - read: The applied config's diagnostics snapshot.
    ///   - onConfigChange: Registers a handler for every config change
    ///     (``GhosttyRuntime/addConfigChangeHandler(_:)``). A service: it follows every change, with
    ///     or without the Settings page shown.
    init(read: @escaping @MainActor () -> GhosttyConfigDiagnosticsSnapshot? = { GhosttyRuntime.shared.configDiagnosticsSnapshot },
         onConfigChange: @MainActor (@escaping @MainActor () -> Void) -> Void = { GhosttyRuntime.shared.addConfigChangeHandler($0) }) {
        self.read = read
        refresh()
        onConfigChange { [weak self] in
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
