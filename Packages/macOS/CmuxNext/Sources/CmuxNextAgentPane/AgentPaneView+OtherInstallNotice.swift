import AppKit

/// One line above the composer while it runs on another cmux install's acpmux (cx-fcaq) and the
/// chat has a request waiting for an answer: that daemon never takes this app's person key, so an
/// allow from this pane is refused there, and the pane says where to approve instead of letting an
/// allow do nothing. With nothing to approve (a chat that allows everything, or no request yet) the
/// line has nothing to say, so it shows only while a request waits. The page draws it in its
/// notice slot (``AgentPaneNotice``): a native label over the page floated over the transcript's
/// first message (Leo, 2026-11-01: "yuck more garbage").
extension AgentPaneView {
    /// The transport's answer: the pane's daemon is another install's.
    func showOtherInstallNotice(_ other: Bool) {
        runsOnOtherInstall = other
        refreshOtherInstallNotice()
    }

    /// Shows or removes the line for the current daemon and the shown chat's waiting requests: any
    /// question, tool permission or pending group member (`hasPending`).
    func refreshOtherInstallNotice() {
        let waiting = model.sessionId.map { model.transport.decisions.hasPending(session: $0) } ?? false
        let shows = Self.showsOtherInstallNotice(otherInstall: runsOnOtherInstall, requestWaiting: waiting)
        guard shows != (otherInstallNotice != nil) else { return }
        otherInstallNotice = shows ? AgentPaneNotice(id: "otherInstall", title: Self.otherInstallMessage) : nil
        pushPaneNotices() // the page draws it above the composer, in the flow (AgentPaneNotice)
    }

    /// The line says where to approve, so it shows only on another install's daemon while the
    /// shown chat has a request to approve.
    nonisolated static func showsOtherInstallNotice(otherInstall: Bool, requestWaiting: Bool) -> Bool {
        otherInstall && requestWaiting
    }
}
