import AppKit
import CMUXMobileCore
import CmuxFoundation
import Foundation
import os

struct AgentChatThemePayload: Codable, Equatable {
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
}

private nonisolated struct AgentChatThemeSyncState {
    var observersInstalled = false
    var lastHealthyURL: URL?
    var lastHealthyAt: Date?
    var debouncedTask: Task<Void, Never>?
}

private nonisolated let agentChatThemeSyncState = OSAllocatedUnfairLock(
    initialState: AgentChatThemeSyncState()
)

enum AgentChatThemeSync {
    private static let healthFreshnessInterval: TimeInterval = 60
    private static let requestTimeout: TimeInterval = 1.5

    static func installObserversIfNeeded() {
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

    static func markHealthy(agentChat: CmuxAgentChatConfiguration) {
        agentChatThemeSyncState.withLock { state in
            state.lastHealthyURL = themeURL(for: agentChat.url)
            state.lastHealthyAt = Date()
        }
    }

    static func syncNowIfRecentlyHealthy() {
        guard let url = recentlyHealthyThemeURL() else { return }
        Task { @MainActor in
            await postResolvedTheme(to: url)
        }
    }

    static func scheduleDebouncedSync() {
        let url = recentlyHealthyThemeURL()
        agentChatThemeSyncState.withLock { state in
            state.debouncedTask?.cancel()
            guard let url else {
                state.debouncedTask = nil
                return
            }
            state.debouncedTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(300))
                } catch {
                    return
                }
                await postResolvedTheme(to: url)
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

    private static func recentlyHealthyThemeURL(now: Date = Date()) -> URL? {
        agentChatThemeSyncState.withLock { state in
            guard let url = state.lastHealthyURL,
                  let lastHealthyAt = state.lastHealthyAt,
                  now.timeIntervalSince(lastHealthyAt) <= healthFreshnessInterval else {
                return nil
            }
            return url
        }
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
            _ = try await URLSession.shared.data(for: request)
        } catch {
            NSLog("[AgentChat] failed to sync theme: %@", String(describing: error))
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
