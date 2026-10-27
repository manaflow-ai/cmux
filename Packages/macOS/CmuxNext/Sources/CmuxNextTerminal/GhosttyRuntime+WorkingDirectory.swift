import Foundation
import GhosttyNextKit

/// Ghostty's `window-inherit-working-directory`, `tab-inherit-working-directory`
/// and `split-inherit-working-directory` (NEW-TERMINAL-INHERITS-CWD, cx-zld).
/// All three default to true, as in Ghostty: a new terminal starts in the
/// focused terminal's folder (the daemon's new-terminal resolver). A key set to
/// false makes that kind of new terminal start in the home folder instead
/// (Ghostty's `working-directory` default for an app launch; the
/// `working-directory` key itself is not read yet).
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

    public init(window: Bool = true, tab: Bool = true, split: Bool = true) {
        self.window = window
        self.tab = tab
        self.split = split
    }

    /// The keys of `config`, a live handle the caller holds for the call.
    init(config: ghostty_config_t) {
        var window = true, tab = true, split = true
        // SAFETY: the caller's live config; the three keys are C bools.
        _ = unsafe GhosttyRuntime.configGet(config, &window, key: "window-inherit-working-directory")
        // SAFETY: as above.
        _ = unsafe GhosttyRuntime.configGet(config, &tab, key: "tab-inherit-working-directory")
        // SAFETY: as above.
        _ = unsafe GhosttyRuntime.configGet(config, &split, key: "split-inherit-working-directory")
        self.init(window: window, tab: tab, split: split)
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
    /// resolver decide), else the home folder.
    public func uninheritedStart(_ kind: Kind, home: String? = nil) -> String? {
        inherits(kind) ? nil : home ?? NSHomeDirectory()
    }
}

extension GhosttyRuntime {
    /// The inherit keys of the applied config; Ghostty's defaults when none loaded.
    public var workingDirectoryInheritance: GhosttyWorkingDirectoryInheritance {
        guard let config else { return GhosttyWorkingDirectoryInheritance() }
        // SAFETY: `config` is the live applied config (GhosttyRuntime's note), held for this call.
        return unsafe GhosttyWorkingDirectoryInheritance(config: config)
    }
}
