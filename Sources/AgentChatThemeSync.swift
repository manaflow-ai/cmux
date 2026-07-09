import AppKit
import CMUXMobileCore
import CmuxFoundation
import Foundation
import os

private nonisolated let agentChatThemeSyncLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentChatThemeSync"
)

nonisolated struct AgentChatThemePayload: Codable, Equatable {
    let background: String
    let foreground: String
    let palette: [String]
    let selectionBackground: String?
    let cursorColor: String?
    let fontFamily: String?
    let fontSize: Double?
    let opacity: Double
    let blur: Double
    let isLight: Bool
    let source: String

    enum CodingKeys: String, CodingKey {
        case background
        case foreground
        case palette
        case selectionBackground
        case cursorColor
        case fontFamily
        case fontSize
        case opacity
        case blur
        case isLight
        case source
    }

    init(config: GhosttyConfig) {
        let terminalTheme = TerminalTheme(ghosttyConfig: config)
        let webTheme = AgentSessionWebTheme.resolve(appearance: .fromConfig(config))
        let trimmedFontFamily = config.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
        let fontSize = Double(config.fontSize)
        background = terminalTheme.background
        foreground = terminalTheme.foreground
        palette = terminalTheme.palette
        selectionBackground = terminalTheme.selectionBackground
        cursorColor = terminalTheme.cursor
        fontFamily = trimmedFontFamily.isEmpty ? nil : trimmedFontFamily
        self.fontSize = fontSize.isFinite && fontSize > 0 ? fontSize : nil
        opacity = min(1, max(0, config.backgroundOpacity))
        blur = config.backgroundBlur.agentChatThemeValue
        isLight = !webTheme.isDark
        source = "cmux"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(background, forKey: .background)
        try container.encode(foreground, forKey: .foreground)
        try container.encode(palette, forKey: .palette)
        try container.encode(selectionBackground, forKey: .selectionBackground)
        try container.encode(cursorColor, forKey: .cursorColor)
        try container.encode(fontFamily, forKey: .fontFamily)
        try container.encode(fontSize, forKey: .fontSize)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(blur, forKey: .blur)
        try container.encode(isLight, forKey: .isLight)
        try container.encode(source, forKey: .source)
    }
}

private nonisolated struct AgentChatThemeSyncState {
    var observersInstalled = false
    var debouncedTask: Task<Void, Never>?
}

private nonisolated let agentChatThemeSyncState = OSAllocatedUnfairLock(
    initialState: AgentChatThemeSyncState()
)

enum AgentChatThemeSync {
    private static let requestTimeout: TimeInterval = 1.5

    @MainActor
    static var isEnabled: Bool {
        CmuxFeatureFlags.shared.isAgentChatUIEnabled
    }

    @MainActor
    static func start() {
        // Observers install unconditionally (they're nearly free) so a
        // runtime flag flip starts syncing without a relaunch; the actual
        // pushes gate on the flag inside syncNow/scheduleDebouncedSync.
        let shouldInstall = agentChatThemeSyncState.withLock { state in
            guard !state.observersInstalled else { return false }
            state.observersInstalled = true
            return true
        }
        guard shouldInstall else { return }

        _ = NotificationCenter.default.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: nil
        ) { _ in
            scheduleDebouncedSync()
        }
        _ = NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: nil
        ) { _ in
            scheduleDebouncedSync()
        }
        // Push once at launch: after a relaunch with an unchanged config the
        // observers above never fire, so an already-running sidecar would keep
        // its file-derived theme. start() runs in AppDelegate.init, which is
        // too early for the resolved config state, so wait for launch.
        if NSApp?.isRunning == true {
            scheduleDebouncedSync()
        } else {
            // didFinishLaunching posts once per process, so the registration
            // can stay put like the two permanent observers above.
            _ = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: nil
            ) { _ in
                scheduleDebouncedSync()
            }
        }
    }

    @MainActor
    static func syncNow(agentChat: CmuxAgentChatConfiguration) {
        guard isEnabled else { return }
        let url = themeURL(for: agentChat)
        Task { @MainActor in
            await postResolvedTheme(to: url)
        }
    }

    static func scheduleDebouncedSync() {
        agentChatThemeSyncState.withLock { state in
            state.debouncedTask?.cancel()
            state.debouncedTask = Task { @MainActor in
                // The flag is MainActor state and this is called from
                // nonisolated notification closures, so gate inside the hop.
                guard isEnabled else { return }
                let clock = ContinuousClock()
                do {
                    try await clock.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
                // Re-check: the flag can flip off during the debounce window.
                guard isEnabled else { return }
                await postResolvedTheme(to: currentThemeURL())
            }
        }
    }

    @MainActor
    static func resolvedPayload() -> AgentChatThemePayload {
        var config = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            reason: "agentChatThemeSync",
            loadConfig: {
                GhosttyConfig.load(globalFontMagnificationPercent: GlobalFontMagnification.storedPercent)
            }
        )
        config.backgroundBlur = GhosttyApp.shared.defaultBackgroundBlur
        return AgentChatThemePayload(config: config)
    }

    static func themeURL(for baseURL: URL) -> URL {
        // Root-anchored like CmuxAgentChatConfiguration.healthURL: the sidecar
        // serves /api/theme at the origin root, so any path in agentChat.url
        // must not prefix the endpoint or every push 404s.
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/api/theme"
        components?.percentEncodedQuery = nil
        components?.fragment = nil
        return components?.url ?? baseURL.appendingPathComponent("api/theme")
    }

    @MainActor
    static func themeURL(for agentChat: CmuxAgentChatConfiguration) -> URL {
        if !agentChat.hasExplicitURL,
           agentChat.startCommand != nil,
           let session = AgentChatActionInFlightGate.ownedServerSession() {
            return session.themeURL
        }
        return themeURL(for: agentChat.url)
    }

    @MainActor
    private static func currentThemeURL() -> URL {
        if let store = AppDelegate.shared?.mainWindowContexts.values.compactMap(\.cmuxConfigStore).first {
            return themeURL(for: store.agentChat)
        }
        return themeURL(for: CmuxAgentChatConfiguration.default.url)
    }

    @MainActor
    private static func postResolvedTheme(to url: URL) async {
        let payload = resolvedPayload()
        await postTheme(payload, to: url)
    }

    private static func postTheme(_ payload: AgentChatThemePayload, to url: URL) async {
        do {
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: requestTimeout
            )
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(payload)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                agentChatThemeSyncLogger.error(
                    "theme sync failed status=\(httpResponse.statusCode, privacy: .public) url=\(url.absoluteString, privacy: .public)"
                )
            }
        } catch {
            await handleThemePostFailure(error, url: url)
        }
    }

    static func handleThemePostFailure(_ error: Error, url: URL) async {
        agentChatThemeSyncLogger.error(
            "failed to sync theme: \(String(describing: error), privacy: .public)"
        )
        guard shouldClearOwnedSessionAfterThemePostFailure(error) else { return }
        await MainActor.run {
            guard let session = AgentChatActionInFlightGate.ownedServerSession(),
                  session.themeURL == url else { return }
            AgentChatActionInFlightGate.clearOwnedServerSession(matching: session)
        }
    }

    static func shouldClearOwnedSessionAfterThemePostFailure(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .cannotConnectToHost,
             .cannotFindHost,
             .dnsLookupFailed,
             .networkConnectionLost,
             .notConnectedToInternet,
             .timedOut:
            return true
        default:
            return false
        }
    }
}

private extension GhosttyBackgroundBlur {
    var agentChatThemeValue: Double {
        switch self {
        case .disabled:
            return 0
        case .radius(let radius):
            return Double(radius)
        case .macosGlassRegular, .macosGlassClear:
            return 1
        }
    }
}
