import Foundation

/// Repository for the close warning settings, persisted in `UserDefaults`
/// under the catalog's `app.warnBeforeClosingTab`,
/// `app.warnBeforeClosingTabXButton`, `app.warnBeforeClosingWorkspace`,
/// `app.warnBeforeClosingWindow`, and
/// `app.hideTabCloseButton` keys.
///
/// Isolation: a stateless `Sendable` struct, not an actor. Every reader is
/// synchronous code that cannot await (close-shortcut handling, tab chrome
/// layout), the struct holds no mutable state, and `UserDefaults` is
/// documented thread-safe, so there is nothing for an actor to protect.
public struct CloseTabWarningStore: CloseTabWarningReading {
    // UserDefaults is documented thread-safe and the reference is immutable.
    private nonisolated(unsafe) let defaults: UserDefaults
    private let keys = AppCatalogSection()

    /// Creates a store reading and writing the given defaults suite.
    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var warnsBeforeClosingTab: Bool {
        keys.warnBeforeClosingTab.value(in: defaults)
    }

    public var warnsBeforeClosingTabXButton: Bool {
        keys.warnBeforeClosingTabXButton.value(in: defaults)
    }

    public var warnsBeforeClosingAgentSession: Bool {
        keys.warnBeforeClosingAgentSession.value(in: defaults)
    }

    public var hidesTabCloseButton: Bool {
        keys.hideTabCloseButton.value(in: defaults)
    }

    public var warnsBeforeClosingWindow: Bool {
        keys.warnBeforeClosingWindow.value(in: defaults)
    }

    /// Whether closing a whole window should show "Close window?". It asks only
    /// when the window setting is on and something would be lost, meaning some
    /// panel in the window needs close confirmation (the same per-panel check
    /// tab and workspace closes use).
    public func shouldConfirmWindowClose(anyPanelNeedsConfirmation: Bool) -> Bool {
        anyPanelNeedsConfirmation && warnsBeforeClosingWindow
    }

    /// Enables or disables the close-shortcut warning.
    public func setWarnsBeforeClosingTab(_ isEnabled: Bool) {
        keys.warnBeforeClosingTab.set(isEnabled, in: defaults)
    }

    /// Whether "Close workspace?" prompts are enabled.
    public var warnsBeforeClosingWorkspace: Bool {
        keys.warnBeforeClosingWorkspace.value(in: defaults)
    }

    /// Turns off the given warnings, for a dialog's "Don't ask again" checkbox.
    public func disableWarnings(_ kinds: CloseWarningKinds) {
        if kinds.contains(.tab) {
            keys.warnBeforeClosingTab.set(false, in: defaults)
        }
        if kinds.contains(.agentSession) {
            keys.warnBeforeClosingAgentSession.set(false, in: defaults)
        }
        if kinds.contains(.tabCloseButton) {
            keys.warnBeforeClosingTabXButton.set(false, in: defaults)
        }
        if kinds.contains(.workspace) {
            keys.warnBeforeClosingWorkspace.set(false, in: defaults)
        }
        if kinds.contains(.window) {
            keys.warnBeforeClosingWindow.set(false, in: defaults)
        }
    }
}
