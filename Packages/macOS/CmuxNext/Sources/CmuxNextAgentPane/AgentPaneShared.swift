public import CmuxNextApps
public import CmuxNextDesign

/// The app-wide objects every agent pane view shares, built once in the composition root and handed to each
/// ``AgentPaneView`` the agent tabs make, so the app holds one value for them, not one field per object.
///
/// - `openPanel`: the app's made-ahead open panel (`AppServices.openPanel`) for Add Files, Attach and a page's
///   file input; nil (tests) shows no file picker.
/// - `eventSources`: the app's table of processes that post input (`AppServices.personInput.sources`): a pane
///   judges whether a key or click is the person's from it, never by a system call per event.
/// - `apps`: the app supervisor's client; each page gets its own ``AppsPanelsPageProvider`` over it (Session Info
///   app sections). Nil (tests): the page has no `cmux.apps.panels.*` ops.
/// - `actAsMe`: the app's one "Computer use can act as me" grant (``AgentPaneActAsMe``); nil (tests) grants nothing.
/// - `flickerLog`: the app run's flicker ring file (``AgentPageFlickerLog/forAppRun()``); nil (tests) writes none.
public struct AgentPaneShared {
    public let openPanel: MadeAheadOpenPanel?
    public let eventSources: EventSourceProcesses
    public let apps: AppsClient?
    public let actAsMe: AgentPaneActAsMe?
    public let flickerLog: AgentPageFlickerLog?

    /// The defaults (tests): no open panel, a posting-process table of the pane's own, no apps, no grant and no flicker log.
    public init(openPanel: MadeAheadOpenPanel? = nil, eventSources: EventSourceProcesses = EventSourceProcesses(), apps: AppsClient? = nil,
                actAsMe: AgentPaneActAsMe? = nil, flickerLog: AgentPageFlickerLog? = nil) {
        self.openPanel = openPanel
        self.eventSources = eventSources
        self.apps = apps
        self.actAsMe = actAsMe
        self.flickerLog = flickerLog
    }
}

extension AgentPaneView {
    /// A pane over the app's shared objects (``AgentPaneShared``); the other parameters are as in the designated init.
    public convenience init?(model: AgentPaneModel, source: AgentPaneSource? = nil, renderRate: AgentPaneRenderRate = .capped,
                             pageHost: Bool = false, shared: AgentPaneShared) {
        self.init(model: model, source: source, renderRate: renderRate, pageHost: pageHost, panelProvider: shared.apps.map(AppsPanelsPageProvider.init(client:)),
                  openPanel: shared.openPanel, eventSources: shared.eventSources, flickerLog: shared.flickerLog)
        model.transport.gestures.actAsMe = shared.actAsMe
        showActAsMe(shared.actAsMe)
    }
}
