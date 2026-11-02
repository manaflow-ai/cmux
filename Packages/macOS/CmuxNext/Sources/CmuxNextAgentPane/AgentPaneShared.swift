public import CmuxNextDesign

/// The app-wide objects every agent pane view shares, built once in the composition root and handed to each
/// ``AgentPaneView`` the agent tabs make, so the app holds one value for them, not one field per object.
///
/// - `openPanel`: the app's made-ahead open panel (`AppServices.openPanel`) for Add Files, Attach and a page's
///   file input; nil (tests) shows no file picker.
/// - `eventSources`: the app's table of processes that post input (`AppServices.personInput.sources`): a pane
///   judges whether a key or click is the person's from it, never by a system call per event.
public struct AgentPaneShared {
    public let openPanel: MadeAheadOpenPanel?
    public let eventSources: EventSourceProcesses

    /// The defaults (tests): no open panel, and a posting-process table of the pane's own.
    public init(openPanel: MadeAheadOpenPanel? = nil, eventSources: EventSourceProcesses = EventSourceProcesses()) {
        self.openPanel = openPanel
        self.eventSources = eventSources
    }
}

extension AgentPaneView {
    /// A pane over the app's shared objects (``AgentPaneShared``); the other parameters are as in the designated init.
    public convenience init?(model: AgentPaneModel, source: AgentPaneSource? = nil, renderRate: AgentPaneRenderRate = .capped,
                             pageHost: Bool = false, shared: AgentPaneShared) {
        self.init(model: model, source: source, renderRate: renderRate, pageHost: pageHost, openPanel: shared.openPanel,
                  eventSources: shared.eventSources)
    }
}
