import AppKit
import Foundation
import WebKit

/// Native bridge for the diff viewer webview's review comments: per-repo
/// comment persistence plus registration into the workspace's pending
/// submission pool (consumed by whichever terminal TextBox submits first).
///
/// Only main-frame pages served from a registered diff viewer session (custom
/// `cmux-diff-viewer://` scheme or the local HTTP server form) may call it;
/// every other page gets a `not_allowed` reply.
@MainActor
final class DiffCommentsBridge: NSObject, WKScriptMessageHandlerWithReply {
    static let handlerName = "cmuxDiffComments"
    static let shared = DiffCommentsBridge()

    private static var handlerInstalledKey: UInt8 = 0
    private static var panelAssociationKey: UInt8 = 0

    private final class PanelAssociation: NSObject {
        let panelId: UUID
        let workspaceId: UUID

        init(panelId: UUID, workspaceId: UUID) {
            self.panelId = panelId
            self.workspaceId = workspaceId
        }
    }

    private enum BridgeError: Error {
        case notAllowed
        case invalidRequest(String)

        var code: String {
            switch self {
            case .notAllowed: return "not_allowed"
            case .invalidRequest: return "invalid_request"
            }
        }

        var userMessage: String {
            switch self {
            case .notAllowed:
                return String(
                    localized: "diffComments.bridge.notAllowed",
                    defaultValue: "This page cannot use diff comments."
                )
            case .invalidRequest(let detail):
                return detail
            }
        }
    }

    private let store: DiffCommentStore

    init(store: DiffCommentStore? = nil) {
        // Default resolved in the MainActor body: a `.shared` default argument
        // would evaluate in the caller's nonisolated context and warn.
        self.store = store ?? DiffCommentStore.shared
    }

    /// Adds the reply handler to a user content controller exactly once.
    static func installIfNeeded(on userContentController: WKUserContentController) {
        guard objc_getAssociatedObject(userContentController, &handlerInstalledKey) == nil else {
            return
        }
        userContentController.addScriptMessageHandler(
            shared,
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

    /// Records which browser panel owns a web view so the bridge can resolve
    /// the diff viewer's workspace for the pending submission pool.
    static func associate(panelId: UUID, workspaceId: UUID, with webView: WKWebView) {
        objc_setAssociatedObject(
            webView,
            &panelAssociationKey,
            PanelAssociation(panelId: panelId, workspaceId: workspaceId),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard Self.isTrustedDiffViewerFrame(message.frameInfo) else {
            replyHandler(Self.errorReply(BridgeError.notAllowed), nil)
            return
        }
        do {
            let value = try handle(body: message.body, webView: message.webView)
            replyHandler(["ok": true, "value": value], nil)
        } catch let error as BridgeError {
            replyHandler(Self.errorReply(error), nil)
        } catch {
            replyHandler(["ok": false, "error": [:]] as [String: Any], nil)
        }
    }

    private static func errorReply(_ error: BridgeError) -> [String: Any] {
        ["ok": false, "error": ["code": error.code, "userMessage": error.userMessage]]
    }

    static func isTrustedDiffViewerFrame(_ frameInfo: WKFrameInfo) -> Bool {
        frameInfo.isMainFrame && isTrustedDiffViewerURL(frameInfo.request.url)
    }

    static func isTrustedDiffViewerURL(_ url: URL?) -> Bool {
        DiffViewerSessionTrustRegistry.shared.isTrustedDiffViewerURL(url)
    }

    /// Extracts the diff viewer session token from a live page URL. Unlike
    /// `diffViewerComponents(from:)` this ignores the fragment: the viewer's
    /// in-page router rewrites `#cmux-diff-viewer` to `#/cmux-diff-viewer`
    /// once the app boots, so live bridge messages carry a different fragment
    /// than the URL the page was opened with. Token registration (checked by
    /// the caller) remains the trust authority.
    static func diffViewerToken(from url: URL?) -> String? {
        if let components = CmuxDiffViewerURLSchemeHandler.diffViewerComponents(from: url) {
            return components.token
        }
        guard let url,
              url.scheme == "http" || url.scheme == "https",
              url.host == "127.0.0.1" else {
            return nil
        }
        let rawPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let parts = rawPath.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2,
              CmuxDiffViewerURLSchemeHandler.isValidToken(parts[0]),
              CmuxDiffViewerURLSchemeHandler.isValidRequestPath("/" + parts.dropFirst().joined(separator: "/")) else {
            return nil
        }
        return parts[0]
    }

    private func handle(body: Any, webView: WKWebView?) throws -> Any {
        guard let body = body as? [String: Any],
              let method = body["method"] as? String else {
            throw BridgeError.invalidRequest("Malformed bridge request")
        }
        let params = body["params"] as? [String: Any] ?? [:]
        guard let repoRoot = (params["repoRoot"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !repoRoot.isEmpty else {
            throw BridgeError.invalidRequest("Missing repoRoot")
        }

        switch method {
        case "comments.list":
            // Viewer loads repopulate the workspace's pending pool so the
            // TextBox chips survive app restarts and page reloads.
            let comments = store.comments(repoRoot: repoRoot)
            if let workspace = try? resolveWorkspace(for: webView) {
                for comment in comments {
                    registerPending(comment, repoRoot: repoRoot, workspaceId: workspace.id)
                }
            }
            return ["comments": comments.map(Self.commentJSON)]
        case "comments.save":
            guard let commentParams = params["comment"] as? [String: Any],
                  let comment = Self.comment(fromJSON: commentParams) else {
                throw BridgeError.invalidRequest("Malformed comment")
            }
            let saved = store.upsert(comment, repoRoot: repoRoot)
            if let workspace = try? resolveWorkspace(for: webView) {
                registerPending(saved, repoRoot: repoRoot, workspaceId: workspace.id)
            }
            return ["comment": Self.commentJSON(saved)]
        case "comments.delete":
            guard let rawId = params["id"] as? String, let id = UUID(uuidString: rawId) else {
                throw BridgeError.invalidRequest("Missing comment id")
            }
            DiffCommentSubmissionPool.shared.removePending(commentId: id)
            return ["deleted": store.delete(id: id, repoRoot: repoRoot)]
        default:
            throw BridgeError.invalidRequest("Unsupported method '\(method)'")
        }
    }

    private func registerPending(_ comment: DiffComment, repoRoot: String, workspaceId: UUID) {
        guard comment.consumedAt == nil,
              let submissionText = comment.submissionText,
              !submissionText.isEmpty else {
            return
        }
        DiffCommentSubmissionPool.shared.setPending(
            DiffCommentSubmissionPool.Entry(
                commentId: comment.id,
                repoRoot: DiffCommentStore.canonicalRepoRoot(repoRoot),
                submissionText: submissionText
            ),
            workspaceId: workspaceId
        )
    }

    // MARK: - Workspace resolution

    private func resolveWorkspace(for webView: WKWebView?) throws -> Workspace {
        guard let webView,
              let association = objc_getAssociatedObject(
                  webView,
                  &Self.panelAssociationKey
              ) as? PanelAssociation,
              let app = AppDelegate.shared,
              let location = app.workspaceContainingPanel(
                  panelId: association.panelId,
                  preferredWorkspaceId: association.workspaceId
              ) else {
            throw BridgeError.invalidRequest("Diff viewer surface not found")
        }
        return location.workspace
    }

    // MARK: - JSON mapping

    nonisolated private static func commentJSON(_ comment: DiffComment) -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        var json: [String: Any] = [
            "id": comment.id.uuidString,
            "filePath": comment.filePath,
            "side": comment.side,
            "startLine": comment.startLine,
            "endLine": comment.endLine,
            "lineText": comment.lineText,
            "message": comment.message,
            "submissionText": comment.submissionText ?? "",
            "createdAt": formatter.string(from: comment.createdAt),
            "updatedAt": formatter.string(from: comment.updatedAt)
        ]
        if let endSide = comment.endSide {
            json["endSide"] = endSide
        }
        return json
    }

    nonisolated private static func comment(fromJSON json: [String: Any]) -> DiffComment? {
        guard let filePath = json["filePath"] as? String, !filePath.isEmpty,
              let side = json["side"] as? String,
              let startLine = json["startLine"] as? Int,
              let endLine = json["endLine"] as? Int,
              let message = json["message"] as? String else {
            return nil
        }
        let id = (json["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        let now = Date()
        return DiffComment(
            id: id,
            filePath: filePath,
            side: side == "deletions" ? "deletions" : "additions",
            startLine: startLine,
            endLine: endLine,
            endSide: json["endSide"] as? String,
            lineText: json["lineText"] as? String ?? "",
            message: message,
            submissionText: json["submissionText"] as? String,
            consumedAt: nil,
            createdAt: now,
            updatedAt: now
        )
    }
}
