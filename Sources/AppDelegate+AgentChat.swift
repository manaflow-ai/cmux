import AppKit
import Foundation
import os
import Security

nonisolated struct AgentChatActionInFlightGate {
    private struct State {
        var isRunning = false
    }

    private nonisolated static let lock = OSAllocatedUnfairLock(initialState: State())

    static func begin() -> Bool {
        lock.withLock { state in
            guard !state.isRunning else { return false }
            state.isRunning = true
            return true
        }
    }

    static func end() {
        lock.withLock { state in
            state.isRunning = false
        }
    }
}

@MainActor
final class AgentChatOwnedServerRuntime {
    static let shared = AgentChatOwnedServerRuntime()

    private(set) var session: AgentChatOwnedServerSession?

    func update(session: AgentChatOwnedServerSession) {
        self.session = session
    }

    func clearSession(matching candidate: AgentChatOwnedServerSession) {
        guard session == candidate else { return }
        session = nil
    }

    func resetForTesting() {
        session = nil
    }
}

struct AgentChatServerAvailability: Sendable {
    var isReachable: Bool
    var browserURL: URL
}

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
        guard CmuxFeatureFlags.shared.isAgentChatUIEnabled else {
            NSSound.beep()
            return false
        }
        guard BrowserAvailabilitySettings.isEnabled() else {
            NSSound.beep()
            return false
        }
        AgentChatThemeSync.start()
        guard AgentChatActionInFlightGate.begin() else {
            NSSound.beep()
            return false
        }
        Task { @MainActor [weak self, weak tabManager] in
            defer { AgentChatActionInFlightGate.end() }
            guard let self else { return }
            let availability = await self.ensureAgentChatServerAvailable(
                agentChat,
                globalConfigPath: globalConfigPath,
                preferredWindow: preferredWindow
            )
            AgentChatThemeSync.syncNow(agentChat: agentChat)
            guard let tabManager else { return }
            guard let workspace = self.openAgentChatWorkspace(
                tabManager: tabManager,
                url: availability.browserURL
            ) else {
                NSSound.beep()
                return
            }
            if !availability.isReachable {
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
        url: URL
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
                    url: url.absoluteString,
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
    ) async -> AgentChatServerAvailability {
        if await Self.agentChatServerIsHealthy(healthURL: agentChat.healthURL, timeout: 1.5) {
            return AgentChatServerAvailability(isReachable: true, browserURL: agentChat.url)
        }
        guard let startCommand = agentChat.startCommand else {
            return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        }
        if agentChat.hasExplicitURL {
            return await ensureExplicitAgentChatServerAvailable(
                agentChat,
                startCommand: startCommand,
                globalConfigPath: globalConfigPath,
                preferredWindow: preferredWindow
            )
        }
        return await ensureOwnedAgentChatServerAvailable(
            agentChat,
            startCommand: startCommand,
            globalConfigPath: globalConfigPath,
            preferredWindow: preferredWindow
        )
    }

    private func ensureExplicitAgentChatServerAvailable(
        _ agentChat: CmuxAgentChatConfiguration,
        startCommand: String,
        globalConfigPath: String?,
        preferredWindow: NSWindow?
    ) async -> AgentChatServerAvailability {
        let unavailable = AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        guard await authorizeAgentChatStartCommandIfNeeded(
            agentChat,
            command: startCommand,
            globalConfigPath: globalConfigPath,
            preferredWindow: preferredWindow
        ) else {
            return unavailable
        }
        guard Self.launchDetachedAgentChatStartCommand(
            startCommand,
            currentDirectoryURL: Self.agentChatStartCommandDirectoryURL(for: agentChat),
            environmentOverrides: [:]
        ) else {
            return unavailable
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !Task.isCancelled, clock.now < deadline {
            if await Self.agentChatServerIsHealthy(healthURL: agentChat.healthURL, timeout: 1.5) {
                return AgentChatServerAvailability(isReachable: true, browserURL: agentChat.url)
            }
            do {
                // Bounded, cancellable health polling after a configured server start.
                try await clock.sleep(for: .milliseconds(250))
            } catch {
                return unavailable
            }
        }
        return unavailable
    }

    private func ensureOwnedAgentChatServerAvailable(
        _ agentChat: CmuxAgentChatConfiguration,
        startCommand: String,
        globalConfigPath: String?,
        preferredWindow: NSWindow?
    ) async -> AgentChatServerAvailability {
        if let session = AgentChatOwnedServerRuntime.shared.session {
            if await Self.agentChatServerIsHealthy(healthURL: session.healthURL, timeout: 1.5) {
                return AgentChatServerAvailability(isReachable: true, browserURL: session.browserURL)
            }
            AgentChatOwnedServerRuntime.shared.clearSession(matching: session)
        }

        guard let token = Self.generateAgentChatToken(),
              let stateFileURL = Self.agentChatStateFileURL() else {
            return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        }
        try? FileManager.default.removeItem(at: stateFileURL)
        try? FileManager.default.createDirectory(
            at: stateFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        guard await authorizeAgentChatStartCommandIfNeeded(
            agentChat,
            command: startCommand,
            globalConfigPath: globalConfigPath,
            preferredWindow: preferredWindow
        ) else {
            return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        }
        guard Self.launchDetachedAgentChatStartCommand(
            startCommand,
            currentDirectoryURL: Self.agentChatStartCommandDirectoryURL(for: agentChat),
            environmentOverrides: [
                "CMUX_AGENT_CHAT_TOKEN": token,
                "CMUX_AGENT_CHAT_PORT": "0",
                "CMUX_AGENT_CHAT_STATE_FILE": stateFileURL.path,
            ]
        ) else {
            return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        }

        guard let session = await Self.waitForOwnedAgentChatSession(
            stateFileURL: stateFileURL,
            token: token
        ) else {
            return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        }
        AgentChatOwnedServerRuntime.shared.update(session: session)
        let isHealthy = await Self.agentChatServerIsHealthy(healthURL: session.healthURL, timeout: 1.5)
        return AgentChatServerAvailability(isReachable: isHealthy, browserURL: session.browserURL)
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
        currentDirectoryURL: URL,
        environmentOverrides: [String: String]
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
        process.environment = environment.merging(environmentOverrides) { _, override in override }
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

    nonisolated private static func generateAgentChatToken(byteCount: Int = 32) -> String? {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return nil
        }
        return Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated private static func agentChatStateFileURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        return appSupport
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("AgentChat", isDirectory: true)
            .appendingPathComponent("sidecar-\(UUID().uuidString).json")
    }

    nonisolated private static func waitForOwnedAgentChatSession(
        stateFileURL: URL,
        token: String
    ) async -> AgentChatOwnedServerSession? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(10))
        while !Task.isCancelled, clock.now < deadline {
            if let data = try? Data(contentsOf: stateFileURL),
               let session = try? AgentChatSidecarStateFile.parse(data, token: token) {
                return session
            }
            do {
                // Bounded, cancellable polling for the sidecar readiness state file.
                try await clock.sleep(for: .milliseconds(250))
            } catch {
                return nil
            }
        }
        return nil
    }
}
