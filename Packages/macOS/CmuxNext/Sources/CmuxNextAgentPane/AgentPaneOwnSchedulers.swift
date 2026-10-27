import CmuxNextWakeups

// The pane's owners on a main-thread scheduler of their own, for tests and fixtures. Internal, so the app, which
// must pass its one `MainWorkScheduler` and `MainDeadlineScheduler` (`AppServices.mainWork`, `.mainDeadlines`),
// cannot reach them (as `WebKitEngine`'s test init, p06-scheduler-323).

extension AgentPaneModel {
    /// A model on its transport's scheduler, or one of its own.
    convenience init(
        host: any AgentPaneHostProviding,
        sessionId: String? = nil,
        seed: AgentPaneSeedSource? = nil,
        newTab: AgentPaneNewTab? = nil,
        allowsTabConversion: Bool = false,
        transport: AgentPaneTransport? = nil
    ) {
        let work = transport?.mainWork ?? MainWorkScheduler(budget: MainFrameBudget())
        self.init(host: host, sessionId: sessionId, seed: seed, newTab: newTab, allowsTabConversion: allowsTabConversion,
                  transport: transport, deadlines: MainDeadlineScheduler(work: work))
    }
}

extension AgentPaneTransport {
    /// A transport on a scheduler of its own.
    convenience init(limits: Limits = Limits(), pacer: (any AgentPaneTransportPacer)? = nil,
                     gestures: AgentPaneUserGestures = AgentPaneUserGestures()) {
        self.init(limits: limits, pacer: pacer, gestures: gestures, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }
}

extension RemoteAcpmuxWire {
    /// The wire of the chat `session` on a scheduler of its own.
    @MainActor convenience init(client: any AgentSessionRemoteClient, session: String, trust: Trust? = nil) {
        self.init(client: client, session: session, trust: trust, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }

    /// A new chat's wire on a scheduler of its own.
    @MainActor convenience init(start: @escaping Start, trust: Trust? = nil) {
        self.init(start: start, trust: trust, mainWork: MainWorkScheduler(budget: MainFrameBudget()))
    }
}

extension AgentPaneShell {
    /// A shell on a deadline placer of its own.
    convenience init(shell: String?, environment: [String: String], home: String) {
        self.init(shell: shell, environment: environment, home: home,
                  deadlines: MainDeadlineScheduler(work: MainWorkScheduler(budget: MainFrameBudget())))
    }
}
