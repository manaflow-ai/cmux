public import CmuxNextSettings
import Foundation
import WebKit

/// The agent pane's pending permission request, pinned for the app's Allow confirmation
/// (cx-zk9t): the dialog names it, and the confirmed Allow answers only that request at
/// that revision, so a newer or changed request stays pending.
public nonisolated struct AgentPanePermissionPin: Equatable, Sendable {
    public var groupID: String
    public var revision: Int
    /// The requested tools' titles, as the pane's card shows them.
    public var title: String

    public init(groupID: String, revision: Int, title: String) {
        self.groupID = groupID
        self.revision = revision
        self.title = title
    }

    /// The page command's detail (`{groupId, revision}`).
    var detail: JSONValue { ["groupId": .string(groupID), "revision": .number(Double(revision))] }

    /// The pin as an action argument's text: `<revision> <groupId>`.
    public var argumentText: String { "\(revision) \(groupID)" }

    /// The pin an action argument's text carries, else nil.
    public init?(argumentText text: String?) {
        guard let text, let space = text.firstIndex(of: " "), let revision = Int(text[..<space]) else { return nil }
        let groupID = String(text[text.index(after: space)...])
        guard !groupID.isEmpty else { return nil }
        self.init(groupID: groupID, revision: revision, title: "")
    }

    /// The first pending request of `view`'s page, read now; nil when there is none or the
    /// page does not answer within a second.
    @MainActor public static func read(_ view: AgentPaneView) async -> AgentPanePermissionPin? {
        await agentPaneFirst(within: .seconds(1)) { [weak view] in
            guard let webView = view?.webView else { return nil }
            let script = "return window.cmuxAcpmuxPendingPermission?.() ?? null;"
            guard let value = try? await webView.callAsyncJavaScript(script, arguments: [:], contentWorld: .page) as? [String: Any],
                  let groupID = value["groupId"] as? String, let revision = (value["revision"] as? NSNumber)?.intValue else { return nil }
            return AgentPanePermissionPin(groupID: groupID, revision: revision, title: value["title"] as? String ?? "")
        }
    }

    /// Answers this pinned request with `command` (`permissionAllowOnce`, `permissionAllowChat`).
    @MainActor public func answer(_ command: String, in view: AgentPaneView) {
        guard ["permissionAllowOnce", "permissionAllowChat"].contains(command) else { return }
        view.model.transport.gestures.record()
        view.deliver([.command(command, detail: detail)],
                     scripts: ["window.cmuxAcpmuxBridge?.command?.(\"\(command)\", \(detail.compactText));"])
    }
}
