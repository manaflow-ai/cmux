import Bonsplit
import CmuxRemoteSession
import CmuxTmuxControlMode
import Foundation
import GhosttyKit

extension Workspace {
    /// Lands a Harbor row (an attachable tmux/zellij/screen/zmx/herdr/cmux-tui
    /// session, local or on an SSH host) where it was dropped.
    ///
    /// Terminal leaves use their owner's control protocol directly. The
    /// resulting panel is only a renderer, so opening a foreign terminal does
    /// not create a second daemon terminal or an intermediate client TUI.
    /// Session-level rows without a writable pane protocol keep their native
    /// attach command in a normal PTY.
    @discardableResult
    func handleHarborSessionDrop(
        session: HarborSession,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        handleHarborItemDrop(item: .legacySession(session), destination: destination)
    }

    /// Lands one Harbor tree item. A terminal leaf keeps its target identity
    /// in the attach command, so dragging a pane never silently broadens to an
    /// unrelated session.
    @discardableResult
    func handleHarborItemDrop(
        item: HarborDragItem,
        destination: BonsplitController.ExternalTabDropRequest.Destination
    ) -> Bool {
        let shellCommand = HarborAttachCommand.shellCommand(for: item)
#if DEBUG
        cmuxDebugLog("harbor.drop workspace=\(id.uuidString.prefix(5)) item=\(item.title)")
#endif
        if let direct = makeDirectHarborSource(for: item) {
#if DEBUG
            cmuxDebugLog("harbor.drop.direct source=\(direct.source.displayName)")
#endif
            switch destination {
            case .insert(let paneId, _):
                return newHarborManualTerminalSurface(
                    inPane: paneId,
                    source: direct.source,
                    title: direct.title,
                    focus: true,
                    workingDirectory: direct.workingDirectory,
                    keyNameResolver: direct.keyNameResolver
                ) != nil
            case .split(let paneId, let orientation, let insertFirst):
                return splitPaneWithHarborManualTerminal(
                    targetPane: paneId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    source: direct.source,
                    title: direct.title,
                    workingDirectory: direct.workingDirectory,
                    keyNameResolver: direct.keyNameResolver
                ) != nil
            }
        }
#if DEBUG
        cmuxDebugLog("harbor.drop.fallback item=\(item.title)")
#endif
        switch destination {
        case .insert(let paneId, _):
            return newTerminalSurface(
                inPane: paneId,
                focus: true,
                initialCommand: shellCommand
            ) != nil
        case .split(let paneId, let orientation, let insertFirst):
                return splitPaneWithNewTerminal(
                    targetPane: paneId,
                    orientation: orientation,
                    insertFirst: insertFirst,
                    workingDirectory: nil,
                    initialInput: nil,
                    initialCommand: shellCommand
                ) != nil
        }
    }

    /// Builds a source only when the dragged leaf has a documented writable
    /// control protocol and the required local client is installed. Returning
    /// nil is an explicit capability result, so the caller can use the
    /// session's ordinary attach command without creating a misleading
    /// half-attached panel.
    private func makeDirectHarborSource(
        for item: HarborDragItem
    ) -> (
        source: any TerminalSessionSource,
        title: String,
        workingDirectory: String?,
        keyNameResolver: (@MainActor @Sendable (ghostty_input_key_s) -> String?)?
    )? {
        guard case .leaf(let leaf, let title) = item else { return nil }

        switch leaf {
        case .tmuxPane(let host, let sessionName, let windowID, let paneID):
            let target = TmuxAttachTarget.pane(
                sessionName: sessionName,
                windowID: windowID,
                paneID: paneID
            )
            switch host {
            case .local:
                guard let executable = TmuxControlModeGateway.resolveTmuxExecutable() else {
                    return nil
                }
                return (
                    TmuxControlModeGateway(
                        target: target,
                        tmuxExecutablePath: executable
                    ),
                    title,
                    nil,
                    { RemoteTmuxKeyName(inputEvent: $0)?.value }
                )
            case .ssh(let destination):
                guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return (
                    TmuxControlModeGateway(
                        target: target,
                        // The remote branch invokes `tmux` after ssh. This
                        // placeholder is never executed locally.
                        tmuxExecutablePath: "/usr/bin/tmux",
                        remoteDestination: destination
                    ),
                    title,
                    nil,
                    { RemoteTmuxKeyName(inputEvent: $0)?.value }
                )
            }

        case .herdrPane(let host, let sessionName, let paneID):
            return makeHerdrSource(
                host: host,
                sessionName: sessionName,
                target: paneID,
                title: title
            )

        case .herdrTerminal(let host, let sessionName, _, let terminalID):
            return makeHerdrSource(
                host: host,
                sessionName: sessionName,
                target: terminalID,
                title: title
            )

        case .tuiTerminal(let host, let sessionName, let socketPath, let terminalID):
            let target: TuiManualIOPumpPolicy.RelayTarget
            let relayBinary: String
            switch host {
            case .local:
                // The probe only creates a direct-attach leaf after it has
                // verified --pipe-io on this exact binary. Do not run a
                // second asynchronous capability probe here: that race made
                // a valid Harbor row fall back to a client TUI when the cache
                // had not warmed yet. The executable check remains a local
                // launch invariant.
                relayBinary = TuiTerminalAttachBridge.configuredBinaryPath
                guard FileManager.default.isExecutableFile(atPath: relayBinary) else {
                    return nil
                }
                if let socketPath, !socketPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    target = .socket(socketPath)
                } else {
                    target = .session(sessionName)
                }
            case .ssh(let destination):
                guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                // The remote relay executable is OpenSSH. The remote command
                // resolves cmux-tui on the host being attached, so requiring
                // a local cmux-tui binary here would reject a valid remote
                // Harbor leaf for the wrong machine.
                relayBinary = "/usr/bin/cmux-tui"
                target = .sshSession(destination: destination, sessionName: sessionName)
            }
            let pump = TuiManualIOPump(
                binaryPath: relayBinary,
                target: target,
                terminalID: terminalID,
                environment: TuiTerminalAttachBridge.bridgeEnvironment
            )
            return (
                HarborTuiSessionSourceAdapter(
                    pump: pump,
                    displayName: "cmux-tui: \(sessionName):\(terminalID)"
                ),
                title,
                nil,
                nil
            )

        case .zellijPane(let host, let sessionName, let paneID):
            switch host {
            case .local:
                guard let executable = ZellijRenderedSessionGateway.resolveZellijExecutable() else {
                    return nil
                }
                return (
                    ZellijRenderedSessionGateway(
                        sessionName: sessionName,
                        paneID: paneID,
                        zellijExecutablePath: executable
                    ),
                    title,
                    nil,
                    nil
                )
            case .ssh(let destination):
                guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    return nil
                }
                return (
                    ZellijRenderedSessionGateway(
                        sessionName: sessionName,
                        paneID: paneID,
                        // The remote branch runs `zellij` on the SSH host;
                        // this local placeholder is never executed.
                        zellijExecutablePath: "/usr/bin/zellij",
                        remoteDestination: destination
                    ),
                    title,
                    nil,
                    nil
                )
            }
        }
    }

    private func makeHerdrSource(
        host: HarborHostRef,
        sessionName: String,
        target: String,
        title: String
    ) -> (
        source: any TerminalSessionSource,
        title: String,
        workingDirectory: String?,
        keyNameResolver: (@MainActor @Sendable (ghostty_input_key_s) -> String?)?
    )? {
        let executable: String
        let remoteDestination: String?
        switch host {
        case .local:
            // Local control mode executes the installed Herdr client.
            guard let localExecutable = HerdrControlModeGateway.resolveHerdrExecutable() else {
                return nil
            }
            executable = localExecutable
            remoteDestination = nil
        case .ssh(let destination):
            guard !destination.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            // Herdr's --remote option launches its full UI and rejects
            // `terminal session control`. The gateway instead runs the
            // documented control subcommand on the remote host over `ssh -T`,
            // so no local Herdr executable is needed for this branch.
            executable = "/usr/bin/herdr"
            remoteDestination = destination
        }
        return (
            HerdrControlModeGateway(
                sessionName: sessionName,
                target: target,
                herdrExecutablePath: executable,
                remoteDestination: remoteDestination
            ),
            title,
            nil,
            { inputEvent in
                // Herdr's control protocol has a semantic page-key command.
                // Intercept only unmodified PageUp/PageDown; every other
                // physical key remains a raw byte event whose terminal mode
                // is owned by Herdr.
                guard let name = RemoteTmuxKeyName(inputEvent: inputEvent)?.value,
                      name == "PPage" || name == "NPage" else {
                    return nil
                }
                return name
            }
        )
    }

    /// The context-menu / double-click entrypoint: attach into the focused
    /// pane of this workspace as a new tab.
    @discardableResult
    func attachHarborSessionInFocusedPane(session: HarborSession) -> Bool {
        attachHarborItemInFocusedPane(item: .legacySession(session))
    }

    /// Attaches a terminal leaf or a session-level fallback in the selected
    /// workspace. This is the shared action used by Harbor double-click,
    /// Return, and context-menu commands.
    @discardableResult
    func attachHarborItemInFocusedPane(item: HarborDragItem) -> Bool {
        guard let paneId = bonsplitController.focusedPaneId ?? bonsplitController.allPaneIds.first else {
            return false
        }
        return handleHarborItemDrop(item: item, destination: .insert(targetPane: paneId, targetIndex: nil))
    }
}
