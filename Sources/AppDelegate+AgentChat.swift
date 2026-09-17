import AppKit
import CMUXAgentLaunch
import Foundation
import os
import Security

struct AgentChatActionInFlightGate {
    private struct State {
        var isRunning = false
        var ownedServerSession: AgentChatOwnedServerSession?
        var sidecarStateFileStore = AgentChatSidecarStateFileStore.live()
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

    static func ownedServerSession() -> AgentChatOwnedServerSession? {
        lock.withLock { state in
            state.ownedServerSession
        }
    }

    static func updateOwnedServerSession(_ session: AgentChatOwnedServerSession) {
        lock.withLock { state in
            state.ownedServerSession = session
        }
    }

    static func clearOwnedServerSession(matching candidate: AgentChatOwnedServerSession? = nil) {
        lock.withLock { state in
            if let candidate, state.ownedServerSession != candidate { return }
            state.ownedServerSession = nil
        }
    }

    static func sidecarStateFileStore() -> AgentChatSidecarStateFileStore? {
        lock.withLock { state in
            state.sidecarStateFileStore
        }
    }
}

struct AgentChatServerAvailability: Sendable {
    var isReachable: Bool
    /// nil means the owned launch failed and nothing safe exists to open;
    /// the action must fail instead of falling back to the legacy URL.
    var browserURL: URL?
}

extension AppDelegate {
    /// Workstream feed title mapping extracted because `AppDelegate.swift`
    /// sits at its file-length budget.
    nonisolated static func feedWorkstreamTitle(for event: WorkstreamEvent) -> String? {
        switch event.hookEventName {
        case .preCompact, .postCompact:
            return String(localized: "feed.lifecycle.compaction.title", defaultValue: "Compaction")
        case .subagentStart, .subagentStop:
            return String(localized: "feed.lifecycle.subagent.title", defaultValue: "Subagent")
        default:
            return nil
        }
    }

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
            guard let browserURL = availability.browserURL else {
                NSSound.beep()
                self.postAgentChatServerUnavailableNotification(
                    workspace: nil,
                    agentChat: agentChat
                )
                return
            }
            guard let workspace = self.openAgentChatWorkspace(
                tabManager: tabManager,
                url: browserURL
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


    private func ensureAgentChatServerAvailable(
        _ agentChat: CmuxAgentChatConfiguration,
        globalConfigPath: String?,
        preferredWindow: NSWindow?
    ) async -> AgentChatServerAvailability {
        switch agentChat.serverMode {
        case .explicitURL:
            return await ensureExplicitAgentChatServerAvailable(
                agentChat,
                startCommand: agentChat.startCommand,
                globalConfigPath: globalConfigPath,
                preferredWindow: preferredWindow
            )
        case .appOwned:
            guard let startCommand = agentChat.startCommand else {
                return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
            }
            return await ensureOwnedAgentChatServerAvailable(
                agentChat,
                startCommand: startCommand,
                globalConfigPath: globalConfigPath,
                preferredWindow: preferredWindow
            )
        case .legacyDefaultURL:
            let isHealthy = await Self.agentChatServerIsHealthy(healthURL: agentChat.healthURL, timeout: 1.5)
            return AgentChatServerAvailability(isReachable: isHealthy, browserURL: agentChat.url)
        }
    }

    private func ensureExplicitAgentChatServerAvailable(
        _ agentChat: CmuxAgentChatConfiguration,
        startCommand: String?,
        globalConfigPath: String?,
        preferredWindow: NSWindow?
    ) async -> AgentChatServerAvailability {
        if await Self.agentChatServerIsHealthy(healthURL: agentChat.healthURL, timeout: 1.5) {
            return AgentChatServerAvailability(isReachable: true, browserURL: agentChat.url)
        }
        let unavailable = AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        guard let startCommand else { return unavailable }
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
        if let session = AgentChatActionInFlightGate.ownedServerSession() {
            if await Self.agentChatServerIsHealthy(healthURL: session.healthURL, timeout: 1.5) {
                return AgentChatServerAvailability(isReachable: true, browserURL: session.browserURL)
            }
            AgentChatActionInFlightGate.clearOwnedServerSession(matching: session)
            await AgentChatActionInFlightGate.sidecarStateFileStore()?.removeStateFile()
        }

        let launchId = UUID().uuidString
        guard let token = Self.generateAgentChatToken(),
              let stateFileStore = AgentChatActionInFlightGate.sidecarStateFileStore() else {
            return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        }
        let launchDate = Date()
        guard let stateFileURL = await stateFileStore.prepareStateFileURL(
            launchId: launchId,
            launchDate: launchDate
        ) else {
            return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        }

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
                "CMUX_AGENT_CHAT_LAUNCH_ID": launchId,
            ]
        ) else {
            return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        }

        guard let session = await stateFileStore.waitForSession(
            token: token,
            launchId: launchId,
            launchDate: launchDate
        ) else {
            return AgentChatServerAvailability(isReachable: false, browserURL: agentChat.url)
        }
        AgentChatActionInFlightGate.updateOwnedServerSession(session)
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

}
