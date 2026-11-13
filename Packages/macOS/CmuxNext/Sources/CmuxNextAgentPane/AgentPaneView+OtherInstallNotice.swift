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

/// One line above the composer while this pane's connection did not prove the person to its
/// acpmux (`hub/person.rs`): the daemon would record what the person types here as an unverified
/// sender's, and the agent would read it as not theirs (Leo, 2026-11-10: "Oh, it's turned me into
/// an unverified sender."). The transport gets the key to the daemon again and reconnects
/// (``AgentPaneTransport/recoverPersonProof``); the line goes when a connection proves the person.
extension AgentPaneView {
    func showPersonProof(_ proven: Bool) {
        guard proven == (personUnprovenNotice != nil) else { return }
        personUnprovenNotice = proven ? nil : AgentPaneNotice(id: "personUnproven", title: Self.personUnprovenMessage)
        pushPaneNotices()
    }

    /// The host's full lookup for this chat: it hands off a daemon an update replaced and gives
    /// the daemon this launch's person key. True when it finished.
    func recoverPersonProof() async -> Bool {
        do {
            _ = try await model.host.handshake(sessionId: model.sessionId)
            return true
        } catch {
            return false
        }
    }
}
