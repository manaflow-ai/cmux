public import CmuxNextApps
public import CmuxNextDesign
public import CmuxNextPalette
import AppKit

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
/// - `focusLoss`: the app's focus log for a page's `focus-lost` events (``AgentPaneView/onPageFocusLost``); nil (tests) records none.
/// - `newTabText`: the app's one maker and keeper of the JSON text of a New Tab context's shared part
///   (``AgentPaneNewTabText``): each page's model gets it, so the pages of a held New Tab key cost one make.
/// - `lookSound`: the active look's sound pack for a page's finish moments (``AgentPaneFinishSound/lookSource(_:)``,
///   `notifications.sounds.lookPack`); nil (tests) plays only the built-in sounds.
/// - `computerUseState`: the app's one Computer Use Setup, which ``AgentPaneComputerUse`` follows and pushes
///   to every page for the composer's `@computer-use`; nil (tests) pushes nothing, so the page holds no send.
/// - `hostMarks`: the app's host marks (`AppServices.personInput.hostMarks`, ``AgentPaneHostMarks``); nil (tests): a key's mark is never taken back.
/// - `projectPalette`: the app's command palette (`AppServices.palette`), where Add project shows its source pages
///   (``ProjectPaletteBridge``); nil (tests): Add project opens no palette page.
public struct AgentPaneShared {
    public let openPanel: MadeAheadOpenPanel?
    public let eventSources: EventSourceProcesses
    public let apps: AppsClient?
    public let actAsMe: AgentPaneActAsMe?
    public let flickerLog: AgentPageFlickerLog?
    public let focusLoss: AgentPaneView.PageFocusLoss?
    public let newTabText: AgentPaneNewTabText
    public let lookSound: AgentPaneFinishSound.LookSource?
    public let computerUseState: (@MainActor () -> AgentPaneComputerUseState?)?
    /// Follows `computerUseState` and pushes it to every pane's page (one for all the panes).
    public let computerUse: AgentPaneComputerUse
    public let hostMarks: AgentPaneHostMarks?
    public let projectPalette: (@MainActor () -> PaletteController?)?

    /// The defaults (tests): no open panel, a posting-process table of the pane's own, no apps, no grant, no flicker log, no focus log,
    /// a New Tab text of this value's own and no host marks.
    public init(openPanel: MadeAheadOpenPanel? = nil, eventSources: EventSourceProcesses = EventSourceProcesses(), apps: AppsClient? = nil,
                actAsMe: AgentPaneActAsMe? = nil, flickerLog: AgentPageFlickerLog? = nil, focusLoss: AgentPaneView.PageFocusLoss? = nil,
                newTabText: AgentPaneNewTabText = AgentPaneNewTabText(), lookSound: AgentPaneFinishSound.LookSource? = nil,
                hostMarks: AgentPaneHostMarks? = nil,
                computerUseState: (@MainActor () -> AgentPaneComputerUseState?)? = nil,
                projectPalette: (@MainActor () -> PaletteController?)? = nil) {
        self.hostMarks = hostMarks
        self.projectPalette = projectPalette
        self.openPanel = openPanel
        self.eventSources = eventSources
        self.apps = apps
        self.actAsMe = actAsMe
        self.flickerLog = flickerLog
        self.focusLoss = focusLoss
        self.newTabText = newTabText
        self.lookSound = lookSound
        self.computerUseState = computerUseState
        computerUse = AgentPaneComputerUse(read: computerUseState, sources: eventSources)
    }
}

extension AgentPaneView {
    /// A pane over the app's shared objects (``AgentPaneShared``); the other parameters are as in the designated init.
    public convenience init?(model: AgentPaneModel, source: AgentPaneSource? = nil, renderRate: AgentPaneRenderRate = .capped,
                             pageHost: Bool = false, shared: AgentPaneShared) {
        self.init(model: model, source: source, renderRate: renderRate, pageHost: pageHost, panelProvider: shared.apps.map(AppsPanelsPageProvider.init(client:)),
                  openPanel: shared.openPanel, eventSources: shared.eventSources, flickerLog: shared.flickerLog)
        model.transport.gestures.actAsMe = shared.actAsMe
        model.finishSound.lookSound = shared.lookSound
        // Where a look sound's chat sits: its workspace, for a muted one, and whether it is viewed (shown in the key
        // window of the active app), for `unlessViewed`.
        model.finishSound.placement = { [weak self, weak model] in
            let viewed = self.map { $0.window?.isKeyWindow == true && NSApp?.isActive == true && !$0.isHiddenOrHasHiddenAncestor } ?? false
            return AgentPaneFinishSound.Placement(workspace: model?.transport.workspaceID(), viewed: viewed)
        }
        model.hostTouch.marks = shared.hostMarks
        if let projectPalette = shared.projectPalette {
            // The pane's own closures hold the bridge; it holds the pane weakly.
            let bridge = ProjectPaletteBridge(view: self, controller: projectPalette)
            onProjectPaletteRequest = bridge.respond
            onProjectPaletteLayout = { [weak bridge] in bridge?.paneMoved() }
        }
        model.newTabText = shared.newTabText // before the page's first request: a new view's document has no shared text
        onPageFocusLost = shared.focusLoss
        model.computerUse = shared.computerUse
        showActAsMe(shared.actAsMe)
    }
}
