import AppKit
import Foundation
import WebKit

/// Native bridge for the diff viewer webview's review comments: per-repo
/// comment persistence and attaching saved comments to a terminal TextBox.
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

    init(store: DiffCommentStore = .shared) {
        self.store = store
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

    /// Records which browser panel owns a web view so attach targeting can
    /// resolve the diff viewer's workspace.
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

    nonisolated static func isTrustedDiffViewerFrame(_ frameInfo: WKFrameInfo) -> Bool {
        guard frameInfo.isMainFrame,
              let token = diffViewerToken(from: frameInfo.request.url) else {
            return false
        }
        return CmuxDiffViewerURLSchemeHandler.shared.hasActiveSession(token: token)
    }

    /// Extracts the diff viewer session token from a live page URL. Unlike
    /// `diffViewerComponents(from:)` this ignores the fragment: the viewer's
    /// in-page router rewrites `#cmux-diff-viewer` to `#/cmux-diff-viewer`
    /// once the app boots, so live bridge messages carry a different fragment
    /// than the URL the page was opened with. Token registration (checked by
    /// the caller) remains the trust authority.
    nonisolated static func diffViewerToken(from url: URL?) -> String? {
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
            return ["comments": store.comments(repoRoot: repoRoot).map(Self.commentJSON)]
        case "comments.save":
            guard let commentParams = params["comment"] as? [String: Any],
                  let comment = Self.comment(fromJSON: commentParams) else {
                throw BridgeError.invalidRequest("Malformed comment")
            }
            let saved = store.upsert(comment, repoRoot: repoRoot)
            return ["comment": Self.commentJSON(saved)]
        case "comments.delete":
            guard let rawId = params["id"] as? String, let id = UUID(uuidString: rawId) else {
                throw BridgeError.invalidRequest("Missing comment id")
            }
            return ["deleted": store.delete(id: id, repoRoot: repoRoot)]
        case "comments.attach":
            return try handleAttach(params: params, webView: webView)
        default:
            throw BridgeError.invalidRequest("Unsupported method '\(method)'")
        }
    }

    // MARK: - Attach

    struct AttachCandidate {
        let surfaceId: UUID
        let title: String
        let directory: String
        let hasActiveTextBox: Bool
    }

    enum AttachResolution {
        case attach(UUID)
        case picker([AttachCandidate])
        case unavailable
    }

    private func handleAttach(params: [String: Any], webView: WKWebView?) throws -> Any {
        guard let attachmentParams = params["attachment"] as? [String: Any],
              let displayName = attachmentParams["displayName"] as? String,
              let submissionText = attachmentParams["submissionText"] as? String,
              !submissionText.isEmpty else {
            throw BridgeError.invalidRequest("Malformed attachment")
        }
        let submissionPath = attachmentParams["submissionPath"] as? String ?? displayName

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
        let workspace = location.workspace

        let targetParams = params["target"] as? [String: Any]
        let requestedSurfaceId = (targetParams?["surfaceId"] as? String).flatMap(UUID.init(uuidString:))
        let candidates = Self.attachCandidates(in: workspace)
        let resolution = Self.resolveAttachTarget(
            requested: requestedSurfaceId,
            candidates: candidates
        )

        switch resolution {
        case .attach(let surfaceId):
            guard let terminal = workspace.terminalPanel(for: surfaceId) else {
                throw BridgeError.invalidRequest("Terminal no longer exists")
            }
            terminal.insertTextBoxAttachments([
                TextBoxAttachment(
                    displayName: displayName,
                    submissionText: submissionText,
                    submissionPath: submissionPath,
                    localURL: nil
                )
            ])
            return [
                "status": "attached",
                "terminal": [
                    "surfaceId": terminal.id.uuidString,
                    "title": terminal.displayTitle
                ]
            ]
        case .picker(let candidates):
            return [
                "status": "picker",
                "candidates": candidates.map { candidate in
                    [
                        "surfaceId": candidate.surfaceId.uuidString,
                        "title": candidate.title,
                        "directory": candidate.directory,
                        "hasActiveTextBox": candidate.hasActiveTextBox
                    ] as [String: Any]
                }
            ]
        case .unavailable:
            return ["status": "unavailable"]
        }
    }

    private static func attachCandidates(in workspace: Workspace) -> [AttachCandidate] {
        workspace.panels.values
            .compactMap { $0 as? TerminalPanel }
            .map { panel in
                AttachCandidate(
                    surfaceId: panel.id,
                    title: panel.displayTitle,
                    directory: panel.directory,
                    hasActiveTextBox: panel.isTextBoxActive
                )
            }
            .sorted { lhs, rhs in
                if lhs.hasActiveTextBox != rhs.hasActiveTextBox {
                    return lhs.hasActiveTextBox
                }
                return lhs.surfaceId.uuidString < rhs.surfaceId.uuidString
            }
    }

    /// Opener-first targeting: the surface the diff was opened from wins when
    /// it is still a terminal in the diff viewer's workspace and either has
    /// its TextBox open or no other terminal does. An opener whose TextBox is
    /// closed must not silently win over terminals with visibly open
    /// TextBoxes, so that case (and any other ambiguity) becomes a picker.
    /// Without an opener: the only open TextBox wins, then the only terminal.
    static func resolveAttachTarget(
        requested: UUID?,
        candidates: [AttachCandidate]
    ) -> AttachResolution {
        guard !candidates.isEmpty else { return .unavailable }
        let activeTextBoxes = candidates.filter(\.hasActiveTextBox)
        if let requested, let opener = candidates.first(where: { $0.surfaceId == requested }) {
            if opener.hasActiveTextBox || activeTextBoxes.isEmpty {
                return .attach(opener.surfaceId)
            }
            return .picker(candidates)
        }
        if activeTextBoxes.count == 1 {
            return .attach(activeTextBoxes[0].surfaceId)
        }
        if candidates.count == 1 {
            return .attach(candidates[0].surfaceId)
        }
        return .picker(candidates)
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
            createdAt: now,
            updatedAt: now
        )
    }
}
