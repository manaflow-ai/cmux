public import Foundation

/// The subset of a surface tab-bar button the executable-button resolver reads
/// to decide how the button executes.
///
/// The concrete button value (``CmuxSurfaceTabBarButton``) lives app-side and
/// carries presentation fields (title, icon, tooltip) the executor reads later;
/// the resolver only needs these four projections to choose a descriptor by
/// precedence, so it stays generic over the conforming button type. The app
/// button conforms to this protocol, keeping the button type app-side while the
/// resolution map building moves into the package.
public protocol WorkspaceSurfaceTabBarButtonResolvable {
    /// Stable identifier the button advertises; the resolution map key.
    var resolutionID: String { get }

    /// The shell command this button runs, or `nil` when it is not a terminal
    /// command button.
    var resolutionTerminalCommand: String? { get }

    /// The `cmux.json` path the terminal-command action was declared in, used as
    /// the per-button source-path override when present.
    var resolutionActionSourcePath: String? { get }

    /// The button's typed action, inspected for a non-bonsplit built-in.
    var resolutionAction: CmuxSurfaceTabBarButtonAction { get }
}

/// An executable descriptor for one surface tab-bar button: the button paired
/// with the single execution mechanism it resolved to (a non-bonsplit built-in
/// action, a workspace command, or a terminal command) plus the source path
/// used to authorize project-local terminal commands.
///
/// Built by ``WorkspaceSurfaceTabBarButtonResolution/resolutionMap(buttons:terminalCommandSourcePaths:workspaceCommands:)``
/// over a button list and stored app-side keyed by button id; the workspace then
/// drives execution, the bonsplit appearance, and trust checks off the stored map.
public struct WorkspaceSurfaceTabBarButtonResolution<Button: WorkspaceSurfaceTabBarButtonResolvable>: Sendable
where Button: Sendable {
    /// The originating button, carrying the presentation and execution fields
    /// the executor reads.
    public let button: Button

    /// The non-bonsplit built-in action this button runs, when it resolved to a
    /// built-in (`nil` otherwise).
    public let builtInAction: CmuxSurfaceTabBarBuiltInAction?

    /// The workspace command this button runs, when it resolved to one (`nil`
    /// otherwise).
    public let workspaceCommand: CmuxResolvedCommand?

    /// The `cmux.json` source path for a terminal-command button, used to
    /// authorize project-local commands (`nil` for built-in/workspace buttons).
    public let terminalCommandSourcePath: String?

    /// Creates an executable descriptor.
    public init(
        button: Button,
        builtInAction: CmuxSurfaceTabBarBuiltInAction?,
        workspaceCommand: CmuxResolvedCommand?,
        terminalCommandSourcePath: String?
    ) {
        self.button = button
        self.builtInAction = builtInAction
        self.workspaceCommand = workspaceCommand
        self.terminalCommandSourcePath = terminalCommandSourcePath
    }
}

extension WorkspaceSurfaceTabBarButtonResolution {
    /// Builds the `[id: descriptor]` executable-button map from a button list,
    /// applying the fixed execution precedence: a terminal command wins, else a
    /// workspace command keyed by button id, else a non-bonsplit built-in action.
    ///
    /// Buttons that resolve to none of those (a bonsplit-handled built-in) are
    /// dropped, matching the legacy `compactMap` that returned `nil`. Keys are
    /// unique because each button id appears once.
    ///
    /// - Parameters:
    ///   - buttons: The configured surface tab-bar buttons.
    ///   - terminalCommandSourcePaths: Per-button `cmux.json` source paths, used
    ///     as the terminal-command source path when the button has no
    ///     ``WorkspaceSurfaceTabBarButtonResolvable/resolutionActionSourcePath``.
    ///   - workspaceCommands: Resolved workspace commands keyed by button id.
    /// - Returns: The descriptor for every executable button, keyed by id.
    public static func resolutionMap(
        buttons: [Button],
        terminalCommandSourcePaths: [String: String],
        workspaceCommands: [String: CmuxResolvedCommand]
    ) -> [String: WorkspaceSurfaceTabBarButtonResolution<Button>] {
        Dictionary(
            uniqueKeysWithValues: buttons.compactMap { button in
                if button.resolutionTerminalCommand != nil {
                    return (
                        button.resolutionID,
                        WorkspaceSurfaceTabBarButtonResolution(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: button.resolutionActionSourcePath
                                ?? terminalCommandSourcePaths[button.resolutionID]
                        )
                    )
                }
                if let workspaceCommand = workspaceCommands[button.resolutionID] {
                    return (
                        button.resolutionID,
                        WorkspaceSurfaceTabBarButtonResolution(
                            button: button,
                            builtInAction: nil,
                            workspaceCommand: workspaceCommand,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                if case .builtIn(let builtInAction) = button.resolutionAction,
                   builtInAction.bonsplitAction == nil {
                    return (
                        button.resolutionID,
                        WorkspaceSurfaceTabBarButtonResolution(
                            button: button,
                            builtInAction: builtInAction,
                            workspaceCommand: nil,
                            terminalCommandSourcePath: nil
                        )
                    )
                }
                return nil
            }
        )
    }
}
