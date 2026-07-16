import AppKit
import CMUXAgentLaunch
import CmuxFoundation
import CmuxSettings
import Foundation
import Observation
import WebKit

/// Typed native capability bridge shared by the React Feed surface and its
/// host. `WorkstreamStore` remains the only state owner; the bridge publishes
/// immutable snapshots and routes typed actions through `FeedCoordinator`.
@MainActor
final class FeedSurfaceBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxFeed"

    private static var handlerInstalledKey: UInt8 = 0
    private static var subscriptionGenerationKey: UInt8 = 0
    private let subscribedWebViews = NSHashTable<WKWebView>.weakObjects()
    private var integrationReadiness: [FeedIntegrationReadiness] = []
    private var integrationScanTask: Task<Void, Never>?
    private var settingsObserver: NSObjectProtocol?
    private var themeObserver: NSObjectProtocol?

    override init() {
        super.init()
        integrationReadiness = Self.integrationReadiness(installedSources: nil)
        themeObserver = NotificationCenter.default.addObserver(
            forName: .ghosttyDefaultBackgroundDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishSnapshotToSubscribers()
            }
        }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshIntegrationReadiness()
            }
        }
        refreshIntegrationReadiness()
    }

    deinit {
        integrationScanTask?.cancel()
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        if let themeObserver {
            NotificationCenter.default.removeObserver(themeObserver)
        }
    }

    static func installIfNeeded(on userContentController: WKUserContentController) {
        guard objc_getAssociatedObject(userContentController, &handlerInstalledKey) == nil else {
            return
        }
        userContentController.addScriptMessageHandler(
            FeedSurfaceBridge(),
            contentWorld: .page,
            name: handlerName
        )
        objc_setAssociatedObject(
            userContentController,
            &handlerInstalledKey,
            NSNumber(value: true),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard Self.isTrustedFeedFrame(message.frameInfo),
              let body = message.body as? [String: Any],
              let method = body["method"] as? String else {
            replyHandler(Self.error(code: "not_allowed"), nil)
            return
        }
        let params = body["params"] as? [String: Any] ?? [:]
        Task { @MainActor in
            do {
                let value = try await self.handle(method: method, params: params, webView: message.webView)
                replyHandler(["ok": true, "value": value], nil)
            } catch {
                replyHandler(Self.error(code: "invalid_request"), nil)
            }
        }
    }

    static func isTrustedFeedFrame(_ frameInfo: WKFrameInfo) -> Bool {
        frameInfo.isMainFrame && isTrustedFeedURL(frameInfo.request.url)
    }

    static func isTrustedFeedURL(_ url: URL?, resourceURL: URL? = Bundle.main.resourceURL) -> Bool {
        _ = resourceURL
        guard let url,
              let expected = CmuxDiffViewerURLSchemeHandler.diffViewerURL(
                token: CmuxDiffViewerURLSchemeHandler.bundledFeedToken,
                requestPath: "/feed.html"
              ) else { return false }
        return url == expected
    }

    nonisolated static func isLegacyPackagedFeedURL(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        return url.standardizedFileURL.path.hasSuffix(
            "/Contents/Resources/markdown-viewer/webviews-app/feed.html"
        )
    }

    static func feedURL() -> URL? {
        do {
            return try CmuxDiffViewerURLSchemeHandler.shared.registerBundledFeedAssets()
        } catch {
            NSLog("feed.surface.register.failed error=%@", String(describing: error))
            return nil
        }
    }

    private func handle(
        method: String,
        params: [String: Any],
        webView: WKWebView?
    ) async throws -> Any {
        switch method {
        case "feed.snapshot":
            return snapshot()
        case "feed.subscribe":
            guard let webView else { throw FeedSurfaceBridgeError.invalidRequest }
            beginSnapshotSubscription(for: webView)
            return snapshot()
        case "feed.loadOlder":
            await FeedCoordinator.shared.store?.loadOlderItems()
            return snapshot()
        case "feed.permission.reply":
            let item = try item(params)
            guard let modeRaw = params["mode"] as? String,
                  let mode = WorkstreamPermissionMode(rawValue: modeRaw),
                  isAllowedPermissionMode(mode, for: item) else {
                throw FeedSurfaceBridgeError.invalidRequest
            }
            FeedCoordinator.shared.deliverReply(
                requestId: try requestID(item),
                decision: .permission(mode)
            )
            return ["accepted": true]
        case "feed.exitPlan.reply":
            let item = try item(params)
            guard let modeRaw = params["mode"] as? String,
                  let mode = WorkstreamExitPlanMode(rawValue: modeRaw) else {
                throw FeedSurfaceBridgeError.invalidRequest
            }
            let feedback = (params["feedback"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            FeedCoordinator.shared.deliverReply(
                requestId: try requestID(item),
                decision: .exitPlan(mode, feedback: feedback?.isEmpty == false ? feedback : nil)
            )
            return ["accepted": true]
        case "feed.question.reply":
            let item = try item(params)
            guard let selections = params["selections"] as? [String] else {
                throw FeedSurfaceBridgeError.invalidRequest
            }
            FeedCoordinator.shared.deliverReply(
                requestId: try requestID(item),
                decision: .question(selections: selections)
            )
            return ["accepted": true]
        case "feed.jump":
            guard let workstreamID = params["workstreamId"] as? String else {
                throw FeedSurfaceBridgeError.invalidRequest
            }
            return ["matched": FeedCoordinator.shared.focusIfPossible(workstreamId: workstreamID)]
        case "feed.sendText":
            guard let workstreamID = params["workstreamId"] as? String,
                  let text = params["text"] as? String else {
                throw FeedSurfaceBridgeError.invalidRequest
            }
            return ["sent": FeedCoordinator.shared.sendTextToWorkstream(workstreamId: workstreamID, text: text)]
        default:
            throw FeedSurfaceBridgeError.invalidRequest
        }
    }

    private func item(_ params: [String: Any]) throws -> WorkstreamItem {
        guard let rawID = params["itemId"] as? String,
              let id = UUID(uuidString: rawID),
              let item = FeedCoordinator.shared.store?.items.first(where: { $0.id == id }),
              item.status.isPending else {
            throw FeedSurfaceBridgeError.invalidRequest
        }
        return item
    }

    private func requestID(_ item: WorkstreamItem) throws -> String {
        switch item.payload {
        case .permissionRequest(let requestID, _, _, _),
             .exitPlan(let requestID, _, _),
             .question(let requestID, _):
            return requestID
        default:
            throw FeedSurfaceBridgeError.invalidRequest
        }
    }

    private func snapshot() -> [String: Any] {
        let store = FeedCoordinator.shared.store
        let background = GhosttyApp.shared.defaultBackgroundColor
        let foreground = GhosttyApp.shared.defaultForegroundColor
        return [
            "items": (store?.items ?? []).map(itemDictionary),
            "integrations": integrationReadiness.map(\.dictionary),
            "sourceIcons": Self.sourceIconDataURLs,
            "sourceLabels": Self.sourceLabels,
            "theme": [
                "background": background.hexString(),
                "foreground": foreground.hexString(),
                "isLight": cmuxReadableColorScheme(for: background) == .light,
            ],
            "hasMore": store?.hasMorePersistedItems ?? false,
            "isLoadingOlder": store?.isLoadingOlderItems ?? false,
            "copy": [
                "feed": String(localized: "rightSidebar.mode.feed", defaultValue: "Feed"),
                "actionable": String(localized: "feed.filter.actionable", defaultValue: "Actionable"),
                "activity": String(localized: "feed.filter.activity", defaultValue: "All Activity"),
                "emptyActionable": String(localized: "feed.empty.actionable.title", defaultValue: "No pending decisions"),
                "emptyActionableDescription": String(localized: "feed.empty.actionable.subtitle", defaultValue: "Permission, plan, and question requests from AI agents will appear here."),
                "emptyActivity": String(localized: "feed.empty.activity.title", defaultValue: "No activity yet"),
                "emptyActivityDescription": String(localized: "feed.empty.all.subtitle", defaultValue: "Tool use, messages, and session events will appear here."),
                "integrationsTitle": String(localized: "feed.integrations.title", defaultValue: "Agent integrations"),
                "integrationReady": String(localized: "feed.integrations.status.ready", defaultValue: "Ready"),
                "integrationDisabled": String(localized: "feed.integrations.status.disabled", defaultValue: "Disabled in Settings"),
                "integrationNeedsSetup": String(localized: "feed.integrations.status.needsSetup", defaultValue: "Setup needed"),
                "integrationChecking": String(localized: "feed.integrations.status.checking", defaultValue: "Checking..."),
                "integrationHint": String(localized: "feed.integrations.hint", defaultValue: "Claude Code and Codex use Settings. Other agents need `cmux hooks setup`."),
                "keyboardHelp": String(localized: "feed.keyboard.help", defaultValue: "Navigate with ↑/↓, J/K, or Control-N/Control-P. Press Tab to reach actions."),
                "loadOlder": String(localized: "feed.history.loadOlder", defaultValue: "Load older activity"),
                "loadingOlder": String(localized: "feed.history.loadingOlder", defaultValue: "Loading older activity..."),
                "deny": String(localized: "feed.permission.deny", defaultValue: "Deny"),
                "allowOnce": String(localized: "feed.permission.once", defaultValue: "Allow Once"),
                "allowAlways": String(localized: "feed.permission.always", defaultValue: "Always Allow"),
                "allowAll": String(localized: "feed.permission.all", defaultValue: "All tools"),
                "allowBypass": String(localized: "feed.permission.bypass", defaultValue: "Bypass"),
                "planManual": String(localized: "feed.exitplan.manual", defaultValue: "Manual"),
                "planAuto": String(localized: "feed.exitplan.auto", defaultValue: "Auto"),
                "planUltraplan": String(localized: "feed.exitplan.ultraplan", defaultValue: "Ultraplan"),
                "questionSubmit": String(localized: "feed.question.submitAll", defaultValue: "Submit All Answers"),
                "questionPlaceholder": String(localized: "feed.question.typeSomething", defaultValue: "Type something..."),
                "requestFailed": String(localized: "agentSession.web.error.requestFailed", defaultValue: "Native bridge request failed."),
            ],
        ]
    }

    private static let sourceIconDataURLs: [String: String] = {
        let assetNames: [WorkstreamSource: String] = [
            .claude: "AgentIcons/Claude",
            .codex: "AgentIcons/Codex",
            .opencode: "AgentIcons/OpenCode",
            .pi: "AgentIcons/Pi",
            .hermesAgent: "AgentIcons/HermesAgent",
        ]
        return assetNames.reduce(into: [:]) { result, entry in
            guard let image = NSImage(named: NSImage.Name(entry.value)),
                  let tiffData = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiffData),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else {
                return
            }
            result[entry.key.rawValue] = "data:image/png;base64,\(pngData.base64EncodedString())"
        }
    }()

    private static let sourceLabels: [String: String] = [
        WorkstreamSource.claude.rawValue: String(localized: "feed.source.claude", defaultValue: "Claude Code"),
        WorkstreamSource.codex.rawValue: String(localized: "feed.source.codex", defaultValue: "Codex"),
        WorkstreamSource.pi.rawValue: String(localized: "feed.source.pi", defaultValue: "Pi"),
        WorkstreamSource.amp.rawValue: String(localized: "feed.source.amp", defaultValue: "Amp"),
        WorkstreamSource.cursor.rawValue: String(localized: "feed.source.cursor", defaultValue: "Cursor"),
        WorkstreamSource.opencode.rawValue: String(localized: "feed.source.opencode", defaultValue: "OpenCode"),
        WorkstreamSource.gemini.rawValue: String(localized: "feed.source.gemini", defaultValue: "Gemini"),
        WorkstreamSource.hermesAgent.rawValue: String(localized: "feed.source.hermes", defaultValue: "Hermes Agent"),
        WorkstreamSource.copilot.rawValue: String(localized: "feed.source.copilot", defaultValue: "Copilot"),
        WorkstreamSource.codebuddy.rawValue: String(localized: "feed.source.codebuddy", defaultValue: "CodeBuddy"),
        WorkstreamSource.factory.rawValue: String(localized: "feed.source.factory", defaultValue: "Factory"),
        WorkstreamSource.qoder.rawValue: String(localized: "feed.source.qoder", defaultValue: "Qoder"),
    ]

    private static let integrationSources: [WorkstreamSource] = [
        .claude,
        .codex,
        .cursor,
        .gemini,
        .opencode,
        .pi,
        .hermesAgent,
        .copilot,
        .codebuddy,
        .factory,
        .qoder,
    ]

    private static func integrationReadiness(installedSources: Set<String>?) -> [FeedIntegrationReadiness] {
        let settings = AgentIntegrationSettingsStore(defaults: .standard)
        return integrationSources.map { source in
            let status: FeedIntegrationStatus
            switch source {
            case .claude:
                status = settings.claudeCodeHooksEnabled ? .ready : .disabled
            case .codex:
                status = settings.codexHooksEnabled ? .ready : .disabled
            case .cursor:
                status = integrationStatus(
                    settingEnabled: settings.cursorHooksEnabled,
                    isInstalled: installedSources?.contains(source.rawValue)
                )
            case .gemini:
                status = integrationStatus(
                    settingEnabled: settings.geminiHooksEnabled,
                    isInstalled: installedSources?.contains(source.rawValue)
                )
            default:
                status = installedSources.map { $0.contains(source.rawValue) ? .ready : .needsSetup } ?? .checking
            }
            return FeedIntegrationReadiness(source: source.rawValue, status: status)
        }
    }

    private static func integrationStatus(settingEnabled: Bool, isInstalled: Bool?) -> FeedIntegrationStatus {
        guard settingEnabled else { return .disabled }
        return isInstalled.map { $0 ? .ready : .needsSetup } ?? .checking
    }

    private func refreshIntegrationReadiness() {
        integrationScanTask?.cancel()
        integrationReadiness = Self.integrationReadiness(installedSources: nil)
        publishSnapshotToSubscribers()
        integrationScanTask = Task { @MainActor [weak self] in
            let installedSources = await Task.detached(priority: .utility) {
                Self.installedFeedHookSources()
            }.value
            guard !Task.isCancelled, let self else { return }
            self.integrationReadiness = Self.integrationReadiness(installedSources: installedSources)
            self.publishSnapshotToSubscribers()
        }
    }

    nonisolated private static func installedFeedHookSources() -> Set<String> {
        let probes = [
            FeedHookProbe(
                source: WorkstreamSource.cursor.rawValue,
                url: configURL(directory: ".cursor", file: "hooks.json"),
                marker: "cmux hooks feed --source"
            ),
            FeedHookProbe(
                source: WorkstreamSource.gemini.rawValue,
                url: configURL(directory: ".gemini", file: "settings.json"),
                marker: "cmux hooks feed --source"
            ),
            FeedHookProbe(
                source: WorkstreamSource.opencode.rawValue,
                url: configURL(
                    directory: ".config/opencode",
                    file: "plugins/cmux-feed.js",
                    environmentOverride: "OPENCODE_CONFIG_DIR"
                ),
                marker: "cmux-feed-plugin-marker"
            ),
            FeedHookProbe(
                source: WorkstreamSource.pi.rawValue,
                url: configURL(
                    directory: ".pi/agent",
                    file: "extensions/cmux-session.ts",
                    environmentOverride: "PI_CODING_AGENT_DIR"
                ),
                marker: "cmux-pi-session-extension-marker v2"
            ),
            FeedHookProbe(
                source: WorkstreamSource.hermesAgent.rawValue,
                url: configURL(directory: ".hermes", file: "config.yaml", environmentOverride: "HERMES_HOME"),
                marker: "cmux hooks feed --source"
            ),
            FeedHookProbe(
                source: WorkstreamSource.copilot.rawValue,
                url: configURL(directory: ".copilot", file: "config.json", environmentOverride: "COPILOT_HOME"),
                marker: "cmux hooks feed --source"
            ),
            FeedHookProbe(
                source: WorkstreamSource.codebuddy.rawValue,
                url: configURL(directory: ".codebuddy", file: "settings.json", environmentOverride: "CODEBUDDY_CONFIG_DIR"),
                marker: "cmux hooks feed --source"
            ),
            FeedHookProbe(
                source: WorkstreamSource.factory.rawValue,
                url: configURL(directory: ".factory", file: "settings.json"),
                marker: "cmux hooks feed --source"
            ),
            FeedHookProbe(
                source: WorkstreamSource.qoder.rawValue,
                url: configURL(directory: ".qoder", file: "settings.json", environmentOverride: "QODER_CONFIG_DIR"),
                marker: "cmux hooks feed --source"
            ),
        ]
        return Set(probes.compactMap { probe in
            guard let contents = try? String(contentsOf: probe.url, encoding: .utf8),
                  contents.contains(probe.marker) else { return nil }
            return probe.source
        })
    }

    nonisolated private static func configURL(
        directory: String,
        file: String,
        environmentOverride: String? = nil
    ) -> URL {
        if let environmentOverride,
           let value = ProcessInfo.processInfo.environment[environmentOverride]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            return URL(fileURLWithPath: NSString(string: value).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent(file, isDirectory: false)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent(file, isDirectory: false)
    }

    private func itemDictionary(_ item: WorkstreamItem) -> [String: Any] {
        var dictionary = FeedSocketEncoding.itemDict(item)
        guard case .permissionRequest(_, _, let toolInputJSON, _) = item.payload else {
            return dictionary
        }
        dictionary["allowed_permission_modes"] = WorkstreamPermissionMode.allCases
            .filter { isAllowedPermissionMode($0, for: item, toolInputJSON: toolInputJSON) }
            .map(\.rawValue)
        return dictionary
    }

    private func isAllowedPermissionMode(
        _ mode: WorkstreamPermissionMode,
        for item: WorkstreamItem,
        toolInputJSON explicitToolInputJSON: String? = nil
    ) -> Bool {
        let toolInputJSON: String?
        if let explicitToolInputJSON {
            toolInputJSON = explicitToolInputJSON
        } else if case .permissionRequest(_, _, let value, _) = item.payload {
            toolInputJSON = value
        } else {
            return false
        }
        switch mode {
        case .deny:
            return true
        case .once:
            return FeedPermissionActionPolicy.supportsOncePermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            )
        case .always:
            return FeedPermissionActionPolicy.supportsAlwaysPermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            )
        case .all:
            return FeedPermissionActionPolicy.supportsAllPermissionMode(
                source: item.source,
                toolInputJSON: toolInputJSON
            )
        case .bypass:
            return FeedPermissionActionPolicy.supportsBypassPermissions(source: item.source)
        }
    }

    private func beginSnapshotSubscription(for webView: WKWebView) {
        subscribedWebViews.add(webView)
        let generation = (objc_getAssociatedObject(webView, &Self.subscriptionGenerationKey) as? NSNumber)?.intValue ?? 0
        let nextGeneration = generation + 1
        objc_setAssociatedObject(
            webView,
            &Self.subscriptionGenerationKey,
            NSNumber(value: nextGeneration),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        armSnapshotSubscription(for: webView, generation: nextGeneration)
    }

    private func armSnapshotSubscription(for webView: WKWebView, generation: Int) {
        guard Self.subscriptionGeneration(for: webView) == generation else { return }
        withObservationTracking {
            _ = FeedCoordinator.shared.store?.items
            _ = FeedCoordinator.shared.store?.hasMorePersistedItems
            _ = FeedCoordinator.shared.store?.isLoadingOlderItems
        } onChange: { [weak self, weak webView] in
            Task { @MainActor in
                guard let self, let webView,
                      Self.subscriptionGeneration(for: webView) == generation else { return }
                self.publishSnapshot(to: webView)
                self.armSnapshotSubscription(for: webView, generation: generation)
            }
        }
    }

    private static func subscriptionGeneration(for webView: WKWebView) -> Int {
        (objc_getAssociatedObject(webView, &subscriptionGenerationKey) as? NSNumber)?.intValue ?? 0
    }

    private func publishSnapshot(to webView: WKWebView) {
        let event: [String: Any] = ["type": "feed.snapshot", "snapshot": snapshot()]
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.cmuxFeedBridge?.receive(\(json));")
    }

    private func publishSnapshotToSubscribers() {
        for webView in subscribedWebViews.allObjects {
            publishSnapshot(to: webView)
        }
    }

    private static func error(code: String) -> [String: Any] {
        ["ok": false, "error": ["code": code]]
    }
}

private enum FeedSurfaceBridgeError: Error {
    case invalidRequest
}

private enum FeedIntegrationStatus: String, Sendable {
    case checking
    case disabled
    case needsSetup
    case ready
}

private struct FeedIntegrationReadiness: Sendable {
    let source: String
    let status: FeedIntegrationStatus

    var dictionary: [String: String] {
        ["source": source, "status": status.rawValue]
    }
}

private struct FeedHookProbe: Sendable {
    let source: String
    let url: URL
    let marker: String
}
