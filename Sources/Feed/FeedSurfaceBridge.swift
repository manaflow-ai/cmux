import AppKit
import CMUXAgentLaunch
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

    static func feedURL() -> URL? {
        try? CmuxDiffViewerURLSchemeHandler.shared.registerBundledFeedAssets()
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
        return [
            "items": (store?.items ?? []).map(itemDictionary),
            "hasMore": store?.hasMorePersistedItems ?? false,
            "isLoadingOlder": store?.isLoadingOlderItems ?? false,
            "copy": [
                "feed": String(localized: "rightSidebar.mode.feed", defaultValue: "Feed"),
                "actionable": String(localized: "feed.filter.actionable", defaultValue: "Actionable"),
                "activity": String(localized: "feed.filter.activity", defaultValue: "All Activity"),
                "emptyActionable": String(localized: "feed.empty.actionable.title", defaultValue: "No pending decisions"),
                "emptyActivity": String(localized: "feed.empty.activity.title", defaultValue: "No activity yet"),
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

    private static func error(code: String) -> [String: Any] {
        ["ok": false, "error": ["code": code]]
    }
}

private enum FeedSurfaceBridgeError: Error {
    case invalidRequest
}
