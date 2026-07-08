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

    static func start() {
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
    }

    static func syncNow(agentChat: CmuxAgentChatConfiguration) {
        let url = themeURL(for: agentChat.url)
        Task { @MainActor in
            await postResolvedTheme(to: url)
        }
    }

    static func scheduleDebouncedSync() {
        agentChatThemeSyncState.withLock { state in
            state.debouncedTask?.cancel()
            state.debouncedTask = Task { @MainActor in
                let clock = ContinuousClock()
                do {
                    try await clock.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
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
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.percentEncodedPath = "/" + ([basePath, "api/theme"].filter { !$0.isEmpty }.joined(separator: "/"))
        components?.percentEncodedQuery = nil
        components?.fragment = nil
        return components?.url ?? baseURL.appendingPathComponent("api/theme")
    }

    @MainActor
    private static func currentThemeURL() -> URL {
        if let store = AppDelegate.shared?.mainWindowContexts.values.compactMap(\.cmuxConfigStore).first {
            return themeURL(for: store.agentChat.url)
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
            agentChatThemeSyncLogger.error(
                "failed to sync theme: \(String(describing: error), privacy: .public)"
            )
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
