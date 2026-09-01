import AppKit
import CMUXMobileCore
import CmuxFoundation
import Foundation
import os

private nonisolated let agentChatThemeSyncLogger = Logger(
    subsystem: "com.cmuxterm.app",
    category: "AgentChatThemeSync"
)

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

    /// Builds the web theme payload from the resolved terminal configuration.
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

    /// Encodes nullable optional fields explicitly for the web client.
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

/// Pushes the terminal theme to one app-owned agent-chat server.
///
/// The synchronizer is a composition-root object rather than a static service:
/// its lifecycle and ownership gate are supplied by `AppDelegate`, which keeps
/// tests and multiple app instances from sharing mutable process state.
@MainActor
final class AgentChatThemeSync {
    private static let requestTimeout: TimeInterval = 1.5
    private let gate: AgentChatActionInFlightGate
    private var observersInstalled = false
    private var observerTokens: [NSObjectProtocol] = []
    private var debouncedTask: Task<Void, Never>?

    /// Creates a synchronizer bound to one app-owned sidecar lifecycle.
    init(gate: AgentChatActionInFlightGate) {
        self.gate = gate
    }

    deinit {
        debouncedTask?.cancel()
        for token in observerTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    var isEnabled: Bool {
        CmuxFeatureFlags.shared.isAgentChatUIEnabled
    }

    /// Installs lifecycle observers and schedules the initial theme push.
    func start() {
        // Observers install unconditionally (they're nearly free) so a
        // runtime flag flip starts syncing without a relaunch; the actual
        // pushes gate on the flag inside syncNow/scheduleDebouncedSync.
        guard !observersInstalled else { return }
        observersInstalled = true

        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedSync()
            }
        })
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: .ghosttyConfigDidReload,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.scheduleDebouncedSync()
            }
        })
        // Push once at launch: after a relaunch with an unchanged config the
        // observers above never fire, so an already-running sidecar would keep
        // its file-derived theme. start() runs in AppDelegate.init, which is
        // too early for the resolved config state, so wait for launch.
        if NSApp?.isRunning == true {
            scheduleDebouncedSync()
        } else {
            // didFinishLaunching posts once per process, so the registration
            // can stay put like the two permanent observers above.
            observerTokens.append(NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.scheduleDebouncedSync()
                }
            })
        }
    }

    /// Schedules an immediate theme push for the supplied configuration.
    func syncNow(agentChat: CmuxAgentChatConfiguration) {
        guard isEnabled else { return }
        let url = themeURL(for: agentChat)
        Task { @MainActor [weak self] in
            await self?.postResolvedTheme(to: url)
        }
    }

    /// Coalesces configuration notifications into one cancellable theme push.
    func scheduleDebouncedSync() {
        debouncedTask?.cancel()
        debouncedTask = Task { @MainActor [weak self] in
            guard let self else { return }
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

    /// Resolves the current Ghostty appearance into a sidecar payload.
    static func resolvedPayload() -> AgentChatThemePayload {
        var config = WorkspaceContentView.resolveGhosttyAppearanceConfig(
            reason: "agentChatThemeSync",
            loadConfig: {
                GhosttyConfig.loadForCmux(globalFontMagnificationPercent: GlobalFontMagnification.storedPercent)
            }
        )
        config.backgroundBlur = GhosttyApp.shared.defaultBackgroundBlur
        return AgentChatThemePayload(config: config)
    }

    /// Returns the root-anchored theme endpoint for an arbitrary server URL.
    nonisolated static func themeURL(for baseURL: URL) -> URL {
        // Root-anchored like CmuxAgentChatConfiguration.healthURL: the sidecar
        // serves /api/theme at the origin root, so any path in agentChat.url
        // must not prefix the endpoint or every push 404s.
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/api/theme"
        components?.percentEncodedQuery = nil
        components?.fragment = nil
        return components?.url ?? baseURL.appendingPathComponent("api/theme")
    }

    /// Resolves a tokened owned endpoint or the configured public endpoint.
    func themeURL(for agentChat: CmuxAgentChatConfiguration) -> URL {
        if !agentChat.hasExplicitURL,
           agentChat.startCommand != nil,
           let session = gate.ownedServerSession() {
            return session.themeURL
        }
        return Self.themeURL(for: agentChat.url)
    }

    /// Reads the current window configuration to choose the push destination.
    private func currentThemeURL() -> URL {
        if let store = AppDelegate.shared?.mainWindowContexts.values.compactMap(\.cmuxConfigStore).first {
            return themeURL(for: store.agentChat)
        }
        return themeURL(for: CmuxAgentChatConfiguration.default.url)
    }

    /// Resolves and posts one current theme payload.
    private func postResolvedTheme(to url: URL) async {
        let payload = Self.resolvedPayload()
        await postTheme(payload, to: url)
    }

    /// Performs one HTTP theme request and routes failures to lifecycle cleanup.
    private func postTheme(_ payload: AgentChatThemePayload, to url: URL) async {
        do {
            var request = URLRequest(
                url: url,
                cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
                timeoutInterval: Self.requestTimeout
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

    /// Cleans up the matching owned sidecar after a liveness-related failure.
    func handleThemePostFailure(_ error: Error, url: URL) async {
        agentChatThemeSyncLogger.error(
            "failed to sync theme: \(String(describing: error), privacy: .public)"
        )
        guard Self.shouldClearOwnedSessionAfterThemePostFailure(error) else { return }
        guard let session = gate.ownedServerSession(), session.themeURL == url else {
            return
        }
        // A failed theme POST is one of the sidecar liveness signals.  Do the
        // same identity-safe bounded termination as launch recovery; merely
        // dropping the in-memory PID would orphan the process.  The wait runs
        // off MainActor so a slow sidecar cannot hitch terminal UI updates.
        let didTerminate = await gate.terminateOwnedServerAsync(matching: session)
        if didTerminate, let launchId = session.launchId {
            await gate.sidecarStateFileStore()?.removeStateFile(
                launchId: launchId
            )
        }
    }

    /// Identifies URL failures that indicate the owned server is unavailable.
    nonisolated static func shouldClearOwnedSessionAfterThemePostFailure(_ error: Error) -> Bool {
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
