import AppKit
import Foundation

extension DockSplitStore {
    // MARK: - Panel construction

    func makePanel(
        kind: DockSurfaceKind,
        command: String?,
        url: URL?,
        initialRequest: URLRequest? = nil,
        environment: [String: String],
        workingDirectory: String,
        tmuxStartCommand: String? = nil,
        preferredProfileID: UUID? = nil,
        bypassInsecureHTTPHostOnce: String? = nil
    ) -> (any Panel)? {
        switch kind {
        case .terminal:
            return makeTerminalPanel(
                command: command,
                useLoginShellWrapper: false,
                workingDirectory: workingDirectory,
                environment: environment,
                tmuxStartCommand: tmuxStartCommand,
                controlId: nil,
                controlTitle: nil
            )
        case .browser:
            guard isBrowserPanelAvailable() else {
                if let externalURL = url ?? initialRequest?.url { _ = NSWorkspace.shared.open(externalURL) }
                return nil
            }
            return makeBrowserPanel(
                url: url,
                initialRequest: initialRequest,
                preferredProfileID: preferredProfileID,
                bypassInsecureHTTPHostOnce: bypassInsecureHTTPHostOnce
            )
        }
    }

    func makePanel(
        for def: DockControlDefinition,
        baseDirectory: String,
        resolvedBrowserProfile: DockBrowserProfileResolution?
    ) -> (any Panel)? {
        switch def.variant {
        case .command(let command):
            let workingDirectory = Self.resolvedWorkingDirectory(def.cwd, baseDirectory: baseDirectory)
            return makeTerminalPanel(
                command: command,
                useLoginShellWrapper: true,
                workingDirectory: workingDirectory,
                environment: def.env,
                controlId: def.id,
                controlTitle: def.title
            )
        case .terminal:
            let workingDirectory = Self.resolvedWorkingDirectory(def.cwd, baseDirectory: baseDirectory)
            return makeTerminalPanel(
                command: nil,
                useLoginShellWrapper: false,
                workingDirectory: workingDirectory,
                environment: def.env,
                controlId: def.id,
                controlTitle: def.title
            )
        case .browser(let url, _):
            guard isBrowserPanelAvailable() else { return nil }
            guard let resolvedProfile = resolvedBrowserProfile else {
                return nil
            }
            return makeBrowserPanel(
                url: URL(string: url),
                preferredProfileID: resolvedProfile.id
            )
        }
    }

    func makeTerminalPanel(
        command: String?,
        useLoginShellWrapper: Bool,
        workingDirectory: String,
        environment: [String: String],
        tmuxStartCommand: String? = nil,
        controlId: String?,
        controlTitle: String?
    ) -> TerminalPanel {
        var resolvedEnvironment = environment
        if let controlId { resolvedEnvironment["CMUX_DOCK_CONTROL_ID"] = controlId }
        if let controlTitle { resolvedEnvironment["CMUX_DOCK_CONTROL_TITLE"] = controlTitle }

        let initialCommand: String?
        if let command, !command.isEmpty {
            initialCommand = useLoginShellWrapper
                ? Self.shellStartupScript(command: command, workingDirectory: workingDirectory)
                : command
        } else {
            initialCommand = nil
        }

        return TerminalPanel(
            workspaceId: workspaceId,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialEnvironmentOverrides: resolvedEnvironment,
            focusPlacement: .rightSidebarDock
        )
    }

    func tabKindRaw(_ kind: DockSurfaceKind) -> String {
        switch kind {
        case .terminal: return "terminal"
        case .browser: return "browser"
        }
    }

    func browserProfileIndex() -> DockBrowserProfileIndex {
        let store = browserProfileStore()
        var index = DockBrowserProfileIndex(
            defaultProfileID: store.builtInDefaultProfileID,
            defaultProfileDisplayName: store.displayName(for: store.builtInDefaultProfileID)
        )
        for profile in store.profiles {
            index.addProfile(id: profile.id, displayName: profile.displayName)
        }
        return index
    }
}
