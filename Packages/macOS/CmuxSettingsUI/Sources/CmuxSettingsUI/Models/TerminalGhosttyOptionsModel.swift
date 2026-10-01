import CmuxFoundation
import Foundation
import Observation

/// The Ghostty option values Settings > Terminal shows, shared by the Font card
/// and the options card so an edit in one isn't undone by the other's refresh.
///
/// Each edit shows right away, is written to cmux's Ghostty config after a
/// short pause, and is then checked against a re-read of the effective values.
@MainActor
@Observable
final class TerminalGhosttyOptionsModel {
    /// Coalesces stepper autorepeat and quick clicks into one write and reload.
    private static let writeDelay: Duration = .milliseconds(250)

    @ObservationIgnored private let hostActions: SettingsHostActions
    @ObservationIgnored private let tasks = MainActorTaskStore<GhosttyTerminalOptionKey>()
    /// Changes shown optimistically whose write hasn't finished yet, reapplied
    /// over each re-read so one row's refresh doesn't undo another row's edit.
    @ObservationIgnored private var pendingChanges: [GhosttyTerminalOptionKey: GhosttyTerminalOptionChange] = [:]
    @ObservationIgnored private var isLoading = false

    private(set) var options = GhosttyTerminalOptions.defaults
    private(set) var hasLoaded = false
    /// Installed fixed-pitch families, sorted; empty until loaded.
    private(set) var monospacedFamilies: [String] = []
    private(set) var saveFailed = false
    /// Keys whose written value a later-loading config file overrides, with
    /// that file's display path.
    private(set) var overriddenKeys: [GhosttyTerminalOptionKey: String] = [:]

    init(hostActions: SettingsHostActions) {
        self.hostActions = hostActions
    }

    /// Reads the effective values and the installed monospaced families once.
    func load() async {
        guard !hasLoaded, !isLoading else { return }
        isLoading = true
        let families = Task.detached(priority: .utility) { MonospacedFontFamilies().load() }
        options = await hostActions.terminalGhosttyOptions().options
        hasLoaded = true
        monospacedFamilies = await families.value
        isLoading = false
    }

    /// Installed monospaced families, plus the configured family when it isn't
    /// flagged fixed-pitch, so a picker always shows the current choice.
    var fontFamilyChoices: [String] {
        guard let current = options.fontFamily, !monospacedFamilies.contains(current) else {
            return monospacedFamilies
        }
        return ([current] + monospacedFamilies).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Shows `change` right away, then writes it after a short pause (a newer
    /// change to the same key replaces this task, so stepper autorepeat writes
    /// once), and re-reads the effective values. When a later-loading config
    /// file still overrides the key, the row names that file instead of
    /// silently snapping back.
    func apply(_ change: GhosttyTerminalOptionChange) {
        let key = change.key
        options = options.applying(change)
        pendingChanges[key] = change
        tasks.replaceOnMainActor(key) { [self] in
            try? await Task.sleep(for: Self.writeDelay)
            guard !Task.isCancelled else { return }
            let saved = await hostActions.applyTerminalGhosttyOption(change)
            guard !Task.isCancelled else { return }
            pendingChanges[key] = nil
            saveFailed = !saved
            let snapshot = await hostActions.terminalGhosttyOptions()
            overriddenKeys[key] = saved && !snapshot.options.reflects(change)
                ? snapshot.sourcePaths[key]
                : nil
            options = pendingChanges.values.reduce(snapshot.options) { $0.applying($1) }
        }
    }
}
