import Foundation
import Observation
import CmuxNextTerminal
import CmuxNextWakeups

/// The R92 diagnostics of the applied Ghostty config, kept current: read
/// again on every config change (`GhosttyRuntime.addConfigChangeHandler`). The
/// Settings page's Ghostty group reads it (host lists, live through
/// `cmux.settings.host.changed`); the socket's `ghostty.diagnostics`
/// computes the same list on demand.
@MainActor @Observable
final class GhosttyDiagnosticsModel {
    /// Nil until the first read finished (the page then shows nothing,
    /// never a false "everything applies").
    private(set) var diagnostics: [GhosttyConfigDiagnostic]?
    /// The theme colors the user's Ghostty files set themselves, which no theme can change (the
    /// Theme section's notice). Read with the config, so current at once.
    private(set) var colorOverrides: [GhosttyColorOverride] = []

    @ObservationIgnored private let read: @MainActor () -> GhosttyConfigDiagnosticsSnapshot?
    @ObservationIgnored private let mainWork: MainWorkScheduler
    @ObservationIgnored private let work: BackgroundWork
    @ObservationIgnored private var generation = 0

    /// - Parameters:
    ///   - mainWork: The app's main-thread scheduler each read's answer is posted to.
    ///   - work: Starts each read off main at a stated priority.
    ///   - read: The applied config's diagnostics snapshot.
    ///   - onConfigChange: Registers a handler for every config change
    ///     (``GhosttyRuntime/addConfigChangeHandler(_:)``). A service: it follows every change, with
    ///     or without the Settings page shown.
    init(mainWork: MainWorkScheduler, work: BackgroundWork,
         read: @escaping @MainActor () -> GhosttyConfigDiagnosticsSnapshot? = { GhosttyRuntime.shared.configDiagnosticsSnapshot },
         onConfigChange: @MainActor (@escaping @MainActor () -> Void) -> Void = { GhosttyRuntime.shared.addConfigChangeHandler($0) }) {
        self.mainWork = mainWork
        self.work = work
        self.read = read
        refresh()
        onConfigChange { [weak self] in
            self?.refresh()
        }
    }

    /// Reads the applied config again; the keybind lines are read off the
    /// main actor, and only the newest read is kept. Its answer is one posted `visible` task (the
    /// Settings page lists it).
    func refresh() {
        generation += 1
        let current = generation
        guard let snapshot = read() else {
            diagnostics = []
            colorOverrides = []
            return
        }
        if snapshot.colorOverrides != colorOverrides { colorOverrides = snapshot.colorOverrides }
        let mainWork = mainWork
        // task-owner: one read per config change; a newer read supersedes it (generation).
        work.task(.bestEffort) { [weak self] in
            let found = await snapshot.diagnostics()
            mainWork.postFromAnyThread(.visible, owner: "GhosttyDiagnostics.read") { [weak self] in
                guard let self, generation == current, found != diagnostics else { return }
                diagnostics = found
            }
        }
    }
}
