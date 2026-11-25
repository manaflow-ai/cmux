import CmuxNextWakeups
import Foundation
import GhosttyNextKit

/// Ghostty's `window-inherit-working-directory`, `tab-inherit-working-directory`
/// and `split-inherit-working-directory` (NEW-TERMINAL-INHERITS-CWD, cx-zld).
/// All three default to true, as in Ghostty: a new terminal starts in the
/// focused terminal's folder (the daemon's new-terminal resolver). A key set to
/// false makes that kind of new terminal start in Ghostty's `working-directory`
/// (``configuredStart``) instead, else the home folder (its default for an app
/// launch).
///
/// Where a new terminal starts, first match wins (docs/cmux-next/new-terminal-folder.md):
/// 1. The folder its caller names (`cmux new-workspace --cwd`, `cmux open <dir>`).
/// 2. A new workspace's room (profile) folder, `defaults.cwd`.
/// 3. While its kind inherits: the focused terminal's or agent chat's folder,
///    then (tabs and splits) the daemon's pick among the workspace's terminals.
/// 4. Ghostty's `working-directory` (``configuredStart``).
/// 5. The home folder.
public nonisolated struct GhosttyWorkingDirectoryInheritance: Equatable, Sendable {
    /// What kind of new terminal asks.
    public enum Kind: Sendable {
        /// A new workspace (Ghostty's new window).
        case window
        case tab
        case split
    }

    public var window: Bool
    public var tab: Bool
    public var split: Bool
    /// The folder Ghostty's `working-directory` names on this Mac; nil when the key is unset,
    /// `inherit`, or names no folder (``GhosttyConfigWorkingDirectory``).
    public var configuredStart: String?

    public init(window: Bool = true, tab: Bool = true, split: Bool = true, configuredStart: String? = nil) {
        self.window = window
        self.tab = tab
        self.split = split
        self.configuredStart = configuredStart
    }

    init(config: ghostty_config_t, configuredStart: String?) {
        var window = true, tab = true, split = true
        _ = Self.get(config, &window, key: "window-inherit-working-directory")
        _ = Self.get(config, &tab, key: "tab-inherit-working-directory")
        _ = Self.get(config, &split, key: "split-inherit-working-directory")
        self.init(window: window, tab: tab, split: split, configuredStart: configuredStart)
    }

    /// `ghostty_config_get` for one key, callable off the main actor.
    private static func get<T: BitwiseCopyable>(_ config: ghostty_config_t, _ value: inout T, key: String) -> Bool {
        withUnsafeMutablePointer(to: &value) { pointer in
            key.withCString { ghostty_config_get(config, pointer, $0, UInt(key.utf8.count)) }
        }
    }

    /// Whether a new terminal of `kind` inherits the focused terminal's folder.
    public func inherits(_ kind: Kind) -> Bool {
        switch kind {
        case .window: window
        case .tab: tab
        case .split: split
        }
    }

    /// The folder a new terminal of `kind` must start in when its caller named
    /// none: nil while it inherits (the caller's folder logic and the daemon's
    /// resolver decide), else ``configuredStart``, else the home folder.
    public func uninheritedStart(_ kind: Kind, home: String? = nil) -> String? {
        inherits(kind) ? nil : configuredStart ?? home ?? NSHomeDirectory()
    }
}

extension GhosttyRuntime {
    /// The inherit keys and `working-directory` of the applied config; Ghostty's defaults when none loaded.
    public var workingDirectoryInheritance: GhosttyWorkingDirectoryInheritance {
        guard let config else { return GhosttyWorkingDirectoryInheritance() }
        return GhosttyWorkingDirectoryInheritance(config: config, configuredStart: configuredWorkingDirectory)
    }

    /// The folder a new terminal starts in when nothing names one and it inherits none: on this
    /// Mac (`local`), Ghostty's `working-directory`, else `fallback` (the daemon's default, the
    /// home folder). Another machine keeps `fallback`: a Mac path means nothing there.
    public func defaultTerminalFolder(local: Bool, fallback: String?) -> String? {
        local ? configuredWorkingDirectory ?? fallback : fallback
    }

    /// Ghostty's `working-directory` as a folder on this Mac, as the last config change's read
    /// found it (``refreshConfiguredWorkingDirectory()``).
    private var configuredWorkingDirectory: String? { workingDirectoryValue?.folder }

    /// Reads `working-directory` from the loaded files off the main thread, for this
    /// ``configGeneration``; a later change's read supersedes it. Called on every config change.
    func refreshConfiguredWorkingDirectory() {
        let generation = configGeneration, paths = loadedConfigFiles, home = NSHomeDirectory()
        Task { // task-owner: one short read of the config files per config change; a later generation supersedes it
            let folder = await Task.detached(priority: WorkPriority.userVisible.taskPriority) {
                GhosttyConfigWorkingDirectory.value(inFiles: paths)?.start(home: home, isDirectory: GhosttyConfigWorkingDirectory.isFolder)
            }.value
            guard generation == configGeneration else { return }
            workingDirectoryValue = (generation, folder)
        }
    }
}
