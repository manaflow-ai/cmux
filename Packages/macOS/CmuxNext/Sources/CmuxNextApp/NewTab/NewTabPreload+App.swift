import AppKit
import CmuxNextAgentPane
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextInput
import CmuxNextPages

/// ``NewTabPreload`` on the app's collaborators, and its pure size and timing helpers.
extension NewTabPreload {
    /// The app's adapter (`AppServices.newTabSpares`), on the app's one preload slot: made here with
    /// the app's deadlines and installed on `webUI`, whose memory pressure subscription drops it, unless
    /// installed already. Rendered-parked until spike 090 records its park state: no engine freezes a
    /// slot page yet (p13-webui-028).
    static func app(_ services: AppServices) -> NewTabPreload {
        let slot = services.webUI.preload ?? PagePreloadSlot(parkState: .renderedParked, deadlines: services.mainDeadlines)
        services.webUI.preload = slot
        return NewTabPreload(services: services, slot: slot, memory: services.memoryCoordinator, input: services.inputTap,
                             preloadOnMakeVisible: services.features.isEnabled(.pageRendererAtFirstShow),
                             parksHidden: services.features.isEnabled(.newTabParksHidden))
    }

    /// The adapter on `services`' collaborators (held, not `services`).
    convenience init(services: AppServices, slot: PagePreloadSlot, memory: any MemoryConsumerRegistry,
                     input: any InputObserving, clock: any Clock<Duration> = ContinuousClock(),
                     preloadOnMakeVisible: Bool = false, parksHidden: Bool = false) {
        self.init(slot: slot, agentTabs: services.agentTabs, windows: services.windows, appEvents: services.appEvents,
                  sparePage: { [weak services] in services.map { NewTabPage.sparePage($0) } },
                  memory: memory, input: input, clock: clock, preloadOnMakeVisible: preloadOnMakeVisible, parksHidden: parksHidden)
    }

    /// The size a Cmd-T tab in `pane` shows at: the pane less its tab bar, also where a browser's
    /// header band holds the bar now (the band goes with the browser).
    static func newTabContentSize(in pane: PaneController) -> NSSize {
        let scale = pane.view.window?.backingScaleFactor ?? 2
        let strip = pane.hidesTabBar || pane.isAppPane ? 0 : PaneChromeMetrics.current.resolvedStripHeight(scale: scale)
        return NSSize(width: pane.view.bounds.width, height: max(0, pane.view.bounds.height - strip))
    }

    static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let (seconds, attoseconds) = (ContinuousClock.now - start).components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
