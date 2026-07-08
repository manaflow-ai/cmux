import AppKit
import Foundation

extension AppDelegate {

    @discardableResult
    func performConfiguredNewAgentChatAction(
        context: MainWindowContext,
        preferredWindow: NSWindow?,
        onExecuted: (() -> Void)?
    ) -> Bool {
        let cmuxConfigStore = context.cmuxConfigStore
        return performNewAgentChatAction(
            tabManager: context.tabManager,
            agentChat: cmuxConfigStore?.agentChat ?? .default,
            globalConfigPath: cmuxConfigStore?.globalConfigPath,
            preferredWindow: resolvedWindow(for: context) ?? preferredWindow,
            onExecuted: onExecuted
        )
    }

    @discardableResult
    func executeConfiguredCmuxAction(
        id actionID: String,
        tabManager: TabManager,
        preferredWindow: NSWindow? = nil
    ) -> Bool {
        guard let context = mainWindowContext(for: tabManager),
              let action = context.cmuxConfigStore?.resolvedAction(id: actionID) else {
            return false
        }
        return executeConfiguredCmuxAction(
            action,
            context: context,
            preferredWindow: preferredWindow
        )
    }

    @discardableResult
    func performNewAgentChatAction(
        tabManager: TabManager,
        agentChat: CmuxAgentChatConfiguration,
        globalConfigPath: String?,
        preferredWindow: NSWindow?,
        onExecuted: (() -> Void)? = nil
    ) -> Bool {
        Task { @MainActor [weak self, weak tabManager] in
            guard let self else { return }
            let isReachable = await self.ensureAgentChatServerAvailable(
                agentChat,
                globalConfigPath: globalConfigPath,
                preferredWindow: preferredWindow
            )
            guard let tabManager else { return }
            guard let workspace = self.openAgentChatWorkspace(
                tabManager: tabManager,
                agentChat: agentChat
            ) else {
                NSSound.beep()
                return
            }
            if !isReachable {
                self.postAgentChatServerUnavailableNotification(
                    workspace: workspace,
                    agentChat: agentChat
                )
            }
            onExecuted?()
        }
        return true
    }

    @discardableResult
    private func openAgentChatWorkspace(
        tabManager: TabManager,
        agentChat: CmuxAgentChatConfiguration
    ) -> Workspace? {
        let beforeIds = Set(tabManager.tabs.map(\.id))
        let workspaceName = String(
            localized: "workspace.agentChat.defaultTitle",
            defaultValue: "Agent Chat"
        )
        let workspaceDefinition = CmuxWorkspaceDefinition(
            name: workspaceName,
            layout: .pane(CmuxPaneDefinition(surfaces: [
                CmuxSurfaceDefinition(
                    type: .browser,
                    name: workspaceName,
                    command: nil,
                    cwd: nil,
                    env: nil,
                    url: agentChat.url.absoluteString,
                    focus: true
                ),
            ]))
        )
        let command = CmuxCommandDefinition(
            name: workspaceName,
            workspace: workspaceDefinition
        )
        let baseCwd = tabManager.selectedWorkspace?.currentDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        guard CmuxConfigExecutor.executeWorkspaceCommand(
            command: command,
            workspace: workspaceDefinition,
            tabManager: tabManager,
            baseCwd: baseCwd
        ) else {
            return nil
        }
        return tabManager.tabs.first { !beforeIds.contains($0.id) } ?? tabManager.selectedWorkspace
    }

    private func postAgentChatServerUnavailableNotification(
        workspace: Workspace,
        agentChat: CmuxAgentChatConfiguration
    ) {
        let body: String
        if let startCommand = agentChat.startCommand {
            let format = String(
                localized: "notification.agentChat.serverUnavailable.bodyWithCommand",
                defaultValue: "cmux couldn't reach %@. Start it with: %@"
            )
            body = String(format: format, agentChat.url.absoluteString, startCommand)
        } else {
            let format = String(
                localized: "notification.agentChat.serverUnavailable.bodyDefault",
                defaultValue: "cmux couldn't reach %@. Start the server with cmux-chat or configure agentChat.startCommand in cmux.json."
            )
            body = String(format: format, agentChat.url.absoluteString)
        }
        TerminalNotificationStore.shared.addNotification(
            tabId: workspace.id,
            surfaceId: workspace.focusedPanelId,
            title: String(
                localized: "notification.agentChat.serverUnavailable.title",
                defaultValue: "Agent chat server isn't running"
            ),
            subtitle: String(
                localized: "notification.agentChat.serverUnavailable.subtitle",
                defaultValue: "Opened Agent Chat"
            ),
            body: body,
            cooldownKey: "agent-chat-server-unavailable.\(agentChat.url.absoluteString)",
            cooldownInterval: 30
        )
    }

    private func ensureAgentChatServerAvailable(
        _ agentChat: CmuxAgentChatConfiguration,
        globalConfigPath: String?,
        preferredWindow: NSWindow?
    ) async -> Bool {
        if await Self.agentChatServerIsHealthy(healthURL: agentChat.healthURL, timeout: 1.5) {
            return true
        }
        guard let startCommand = agentChat.startCommand else {
            return false
        }
        guard await authorizeAgentChatStartCommandIfNeeded(
            agentChat,
            command: startCommand,
            globalConfigPath: globalConfigPath,
            preferredWindow: preferredWindow
        ) else {
            return false
        }
        _ = Self.launchDetachedAgentChatStartCommand(
            startCommand,
            currentDirectoryURL: Self.agentChatStartCommandDirectoryURL(for: agentChat)
        )
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !Task.isCancelled, clock.now < deadline {
            if await Self.agentChatServerIsHealthy(healthURL: agentChat.healthURL, timeout: 1.5) {
                return true
            }
            do {
                // Bounded, cancellable health polling after a configured server start.
                try await clock.sleep(for: .milliseconds(250))
            } catch {
                return false
            }
        }
        return false
    }

    private func authorizeAgentChatStartCommandIfNeeded(
        _ agentChat: CmuxAgentChatConfiguration,
        command: String,
        globalConfigPath: String?,
        preferredWindow: NSWindow?
    ) async -> Bool {
        guard agentChat.startCommandRequiresTrust else { return true }
        guard case .local(let sourcePath) = agentChat.source,
              let globalConfigPath else {
            return false
        }
        let descriptor = Self.agentChatStartCommandTrustDescriptor(
            command: command,
            sourcePath: sourcePath
        )
        return await withCheckedContinuation { continuation in
            _ = CmuxConfigExecutor.authorizeProjectAutomationIfNeeded(
                descriptor: descriptor,
                confirm: false,
                configSourcePath: sourcePath,
                globalConfigPath: globalConfigPath,
                displayCommand: command,
                displayTitle: String(localized: "command.newAgentChat.title", defaultValue: "New agent chat"),
                presentingWindow: preferredWindow,
                onAuthorized: {
                    continuation.resume(returning: true)
                },
                onDenied: {
                    continuation.resume(returning: false)
                }
            )
        }
    }

    nonisolated private static func agentChatStartCommandTrustDescriptor(
        command: String,
        sourcePath: String
    ) -> CmuxActionTrustDescriptor {
        CmuxActionTrustDescriptor(
            actionID: "\(CmuxSurfaceTabBarBuiltInAction.newAgentChat.configID).startCommand",
            kind: "agentChatStartCommand",
            command: command,
            target: "agentChatServer",
            workspaceCommand: nil,
            configPath: canonicalAgentChatPath(sourcePath),
            projectRoot: canonicalAgentChatPath(CmuxButtonIcon.projectRoot(forConfigPath: sourcePath)),
            iconFingerprint: nil
        )
    }

    nonisolated private static func agentChatServerIsHealthy(
        healthURL: URL,
        timeout: TimeInterval
    ) async -> Bool {
        var request = URLRequest(
            url: healthURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: timeout
        )
        request.httpMethod = "GET"
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(httpResponse.statusCode)
        } catch {
            return false
        }
    }

    nonisolated private static func agentChatStartCommandDirectoryURL(
        for agentChat: CmuxAgentChatConfiguration
    ) -> URL {
        if case .local(let sourcePath) = agentChat.source {
            return URL(
                fileURLWithPath: canonicalAgentChatPath(CmuxButtonIcon.projectRoot(forConfigPath: sourcePath)),
                isDirectory: true
            )
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    nonisolated private static func launchDetachedAgentChatStartCommand(
        _ command: String,
        currentDirectoryURL: URL
    ) -> Bool {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return false }
        let environment = ProcessInfo.processInfo.environment
        guard let shellPath = environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !shellPath.isEmpty else {
            NSLog("[AgentChat] SHELL is not set; cannot launch startCommand")
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-lc", trimmedCommand]
        process.currentDirectoryURL = currentDirectoryURL
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            return true
        } catch {
            NSLog("[AgentChat] failed to launch startCommand: %@", String(describing: error))
            return false
        }
    }

    nonisolated private static func canonicalAgentChatPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
