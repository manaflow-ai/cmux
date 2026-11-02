import Foundation

/// A notice the pane's native side raises about the chat's agent service: another cmux install's
/// daemon (cx-fcaq), remote approvals off there (cx-0q7o), a peer that did not count this Mac's
/// allow. The page draws it in its notice slot above the composer (`paneNotices`, webviews
/// paneNotices.ts), in the flow with its other notices. It was a background-less native label laid
/// over the page, which floated over the transcript's first message (Leo, 2026-11-01: "yuck more
/// garbage"); the pane now adds no view of its own for it.
@MainActor final class AgentPaneNotice {
    /// Which notice: `otherInstall` or `remoteApprovals`; the page's button names it back.
    let id: String
    let title: String
    /// The line under the title; an action that failed says why here.
    var detail: String?
    /// The button's label; nil: no button.
    let button: String?
    /// Off while the button's action runs.
    var buttonEnabled = true
    /// What the button does; it gets the notice, to update it as it goes.
    let action: (@MainActor (AgentPaneNotice) -> Void)?

    init(id: String, title: String, detail: String? = nil, button: String? = nil, action: (@MainActor (AgentPaneNotice) -> Void)? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.button = button
        self.action = action
    }

    /// The lines a person reads: the title, then the detail.
    var lines: [String] { [title] + (detail.map { [$0] } ?? []) }

    var value: JSONValue {
        var fields: [String: JSONValue] = ["id": .string(id), "title": .string(title)]
        if let detail { fields["detail"] = .string(detail) }
        if let button { fields["button"] = .string(button); fields["enabled"] = .bool(buttonEnabled) }
        return .object(fields)
    }

    /// The `paneNotices` event: every notice shown, in order (none: an empty list).
    static func event(_ notices: [AgentPaneNotice]) -> AgentPageEvent {
        AgentPageEvent(kind: "paneNotices", value: .array(notices.map(\.value)))
    }

    /// The legacy host's script for the same push (`applyPaneNotices`, App.tsx).
    static func script(_ notices: [AgentPaneNotice]) -> String {
        "window.cmuxAcpmuxBridge?.applyPaneNotices?.(\(event(notices).value.compactText));"
    }
}

extension AgentPaneModel {
    /// `pane.noticeAction {id}`: the button restarts or enrolls an agent daemon, so only the
    /// person's own click runs it (the page host's gesture, or the legacy bridge's gesture credit).
    func paneNoticeAction(_ id: String, userGesture: Bool) -> [String: Any] {
        guard let onPaneNoticeAction else { return Self.unsupported("pane.noticeAction") }
        guard userGesture || transport.gestures.consume() else { return Self.transportFailure(.gestureRequired) }
        return onPaneNoticeAction(id) ? AgentPaneReply.success() : Self.unsupported("pane.noticeAction")
    }
}

extension AgentPaneView {
    /// The native notices shown now, in the order the page draws them.
    var paneNotices: [AgentPaneNotice] { [otherInstallNotice, remoteApprovalsNotice].compactMap { $0 } }

    /// Pushes the shown notices to the page, and takes their buttons' clicks.
    func pushPaneNotices() {
        model.onPaneNoticeAction = { [weak self] id in self?.runPaneNoticeAction(id) ?? false }
        let notices = paneNotices
        deliver([AgentPaneNotice.event(notices)], scripts: [AgentPaneNotice.script(notices)])
    }

    /// Runs the button of the notice `id`, as a click does; false without that notice or with its
    /// button off.
    func runPaneNoticeAction(_ id: String) -> Bool {
        guard let notice = paneNotices.first(where: { $0.id == id }), notice.button != nil, notice.buttonEnabled,
              let action = notice.action else { return false }
        action(notice)
        return true
    }
}
