import CmuxNextActions
import CmuxNextBridge
import CmuxNextBrowser
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextFeatures
package import CmuxNextHibernation
import CmuxNextHostPressure
import CmuxNextInput
import CmuxNextMemory
import CmuxNextPages
import CmuxNextResources
import CmuxNextSettings
package import CmuxNextTabs
import CmuxNextWakeups
import CoreGraphics

// Browser hibernation and the memory-budgeted warm sets
// (plans/cmux-next/tab-lifecycle.md).
extension AppServices {
    /// Creates the browser and agent page hibernation and follows `browser.hibernation`. It registers with the app's
    /// one memory coordinator (`memoryCoordinator`) as a lossy consumer, which hands it each level. The terminal warm
    /// set (the one budget of hidden GPU surfaces, a lossless consumer) and the parked workspaces (a lossy one) register
    /// there too; the coordinator releases them one surface or one workspace per frame. It runs before the restore mounts
    /// a page, so the cache hands it every hide, show and screen change; its measurements start after startup (``startHibernationMeasurements()``).
    func startHibernation(settings: SettingsController) {
        followMemorySaver(settings)
        let audible = features.isEnabled(.recentlyAudibleProtection) ? AudibleHistory(mainWork: mainWork) : nil
        let hibernation = BrowserHibernation(cache: cache, memory: memoryCoordinator, deadlines: mainDeadlines, energy: mainWork.energy, audible: audible, followsTabVisibility: features.isEnabled(.chromiumTabVisibility), freezeEligibility: features.isEnabled(.memoryFreezeEligibility))
        cache.hibernation = hibernation
        cache.webKit.hidesHiddenTabs = features.isEnabled(.webkitHiddenTabs) // WebKit tabs follow their hides too
        hibernation.isPinned = { [weak self] key in self?.locateTab(key)?.0.pinned ?? false }
        hibernation.isDownloading = { [weak self] key in self?.cache.pageRequests.downloads.isDownloading(tab: key) ?? false }
        hibernation.measureMemory = { [weak self] in await self?.resources.sample(.everything).browserPageMemory ?? [:] }
        let readCPU = { [work = self.work, mainWork = self.mainWork, tabs = cache.tabRenderers, parent = cache.chromium.source.helperParent] (owner: String) in
            SaverCPUFreeze.measure(owner: owner, work: work, mainWork: mainWork, tabs: tabs) { ChromiumHelperProcess.tabRendererUsage(parent: parent.pid) } }
        hibernation.measureCPU = readCPU("SaverCPUFreeze")
        hibernation.highEnergy = features.isEnabled(.highEnergyTabs) ? HighEnergyTabMonitor(cache: cache, registry: registry, measure: readCPU("HighEnergyTabs")) : nil
        hibernation.activity.isEnabled = features.isEnabled(.memorySaverBackgroundActivity)
        hibernation.discardsGrowingFrozenPages = features.isEnabled(.frozenGrowthDiscard)
        hibernation.discardsAppPages = features.isEnabled(.memoryDiscardPageTabs)
        hibernation.discardsStreamedPages = features.isEnabled(.memoryDiscardRemoteTabs)
        hibernation.freezesOffScreenShownPages = features.isEnabled(.offScreenWindowPageFreeze)
        hibernation.discardsCrashedSubframes = features.isEnabled(.memoryDiscardCrashedSubframes)
        hibernation.openerLinks = { [weak self] in self?.scriptOpenerLinks() ?? [:] }
        hibernation.ranksUrgentDiscards = features.isEnabled(.memoryUrgentDiscardRanking)
        hibernation.admission = WakeAdmission(isEnabled: features.isEnabled(.memoryWakeAdmission), freeBytes: { HostSampler().freePhysicalBytes() })
        hibernation.snapshots.keepsCompressed = features.isEnabled(.compressedSnapshots)
        let agentPages = AgentPageHibernation(services: self)
        memoryHistograms.follow(hibernation, agentPages: agentPages)
        hibernation.agentPages = agentPages
        hibernation.follow(settings)
        hibernation.start()
        startIntentPrewarm(over: hibernation)
        AppMemoryConsumers(services: self).registerHibernationSnapshots(hibernation)  // AppServices+Memory.swift
        cache.warmSetRelease = WarmSetRelease(host: cache, normalCapacity: cache.normalWarmCapacity, registry: memoryCoordinator)
        _ = parkedWorkspaceBudget  // registers with the coordinator before any pressure change reads it
    }

    /// Follows `memory.saver` into the memory coordinator's mode, the current value now (as Chrome's
    /// UserPerformanceTuningManager follows the Memory Saver pref, chrome/browser/performance_manager/
    /// public/user_tuning/user_performance_tuning_manager.h): the managed caches' shares under pressure and, through the
    /// coordinator, the proactive timeouts of every planner that follows the mode (page tabs,
    /// conversations, top pages, parked workspaces). Browser tabs keep `browser.hibernation`.
    /// `background`: nothing on screen changes in the flush's frame. Behind `memorySaverSetting`: off,
    /// the mode stays Balanced, what cmux did before the setting.
    func followMemorySaver(_ settings: SettingsController) {
        guard features.isEnabled(.memorySaverSetting) else { return }
        lifetimeFollowers.append(ServiceObservation(.background, owner: "AppServices.memorySaver", on: mainWork) {
            settings.snapshot.memorySaver
        } apply: { [weak self] mode in self?.memoryCoordinator.mode = mode })
    }

    /// The intent prewarm over `hibernation`, its weak warmer, with a background-class deadline per trigger whose
    /// feature is on: the hover dwell (`intentPrewarmHover`), the key steps (`directionalPrewarm`)
    /// and the press start on a row that commits on its release (`intentPrewarmPress`,
    /// no warmer work on a press's input turn). The app's memory pressure, the feature's dwell
    /// and Energy Saver's inputs as its power. No feature on: no service.
    private func startIntentPrewarm(over hibernation: BrowserHibernation) {
        let hovers = features.isEnabled(.intentPrewarmHover), steps = features.isEnabled(.directionalPrewarm), presses = features.isEnabled(.intentPrewarmPress)
        guard hovers || steps || presses else { return }
        let service = IntentPrewarmService<String>(
            warmer: hibernation, memoryPressure: memoryPressure,
            dwellTimer: hovers ? MainDeadline(owner: "IntentPrewarm.hoverDwell", workClass: .background, scheduler: mainDeadlines) : nil,
            stepTimer: steps ? MainDeadline(owner: "IntentPrewarm.keyStep", workClass: .background, scheduler: mainDeadlines) : nil,
            pressStart: presses ? MainDeadline(owner: "IntentPrewarm.pressStart", workClass: .background, scheduler: mainDeadlines) : nil,
            dwell: Feature.intentPrewarmHover.durationParam("dwell") ?? .milliseconds(200))
        let power = energyMonitor.follow { [weak service] inputs in
            service?.power = IntentPrewarmPower(lowPowerMode: inputs.lowPowerMode, onBattery: inputs.onBattery)
        }
        hibernation.intentPrewarm = (service, power)
        hibernation.prewarmKinds.decodeCover = { [weak self] picture, landed in self?.decodePrewarmCover(picture, landed: landed) }
    }

    /// The intent prewarm's cover decode: `picture` drawn into a bitmap on the `.cpu` lane, never on the main
    /// thread, and handed to `landed` in a background-class main task (Chrome decodes images off its UI thread,
    /// services/data_decoder/public/cpp/decode_image.h).
    func decodePrewarmCover(_ picture: CGImage, landed: @escaping @MainActor @Sendable (CGImage) -> Void) {
        work.run(.userVisible, mayBlock: .cpu) { BrowserPictureView.decoded(picture) }
            .reply(on: mainWork, class: .background, owner: "IntentPrewarm.cover", landed)
    }

    /// The hibernation's measurements, after startup: the hourly footprint samples and the app's one occluded-window
    /// checker (its first pass reports the windows already off screen; principled-audit restoreFrameHold R1). With
    /// `windowOcclusionFamily` it feeds every window's occlusion family, so covered windows stop their frames,
    /// terminals and pages; with `occludedWindowDiscard` the hibernation hears the same judgments of its windows.
    func startHibernationMeasurements() {
        memoryFootprints.start()
        let discards = features.isEnabled(.occludedWindowDiscard) && cache.hibernation != nil, families = features.isEnabled(.windowOcclusionFamily)
        guard discards || families else { return }
        windowOcclusionFamilies = WindowOcclusionChecker.feedingFamilies(
            feedsFamilies: families, workspaceEvents: workspaceEvents, mainWork: mainWork,
            listener: { [weak self] id, offScreen in  // the hibernation hears its own windows only, as its checker did
                guard discards, let self, windows.controllers.contains(where: { controller in controller.window.map { ObjectIdentifier($0) } == id }) else { return }
                cache.windowDidChangeOnScreen(id, offScreen: offScreen)
            }, closed: { [weak self] id in if discards { self?.cache.offScreenWindowDidClose(id) } })
    }

    /// Each tab script opened with a live `window.opener` and its opener, by key (`BrowserScriptOpeners`): the opener groups'
    /// links (`FrozenGrowthRule.openerGroups`). Free with no such tab, else one walk of the tabs, at most once per plan.
    func scriptOpenerLinks() -> [String: String] {
        let scriptOpeners = cache.pageRequests.scriptOpeners
        guard !scriptOpeners.isEmpty else { return [:] }
        let keys = Dictionary(cache.browsers.map { (ObjectIdentifier($0.value.tab), $0.key) }) { first, _ in first }
        return scriptOpeners.openers { keys[ObjectIdentifier($0)] }
    }

    /// The parked workspaces of every window: none at critical memory pressure, one teardown per release
    /// slice. With `memoryDiscardParkedWorkspaces` also
    /// `SubsystemBudget.parkedWorkspaces` across every window and the 15 min idle timeout with
    /// `memoryDiscardParkedIdleTimeout`; off, every parked workspace stays until critical pressure. Its
    /// look runs as background work on one deadline.
    func makeParkedWorkspaceBudget() -> ParkedWorkspaceBudget {
        let budget = SubsystemBudget.forThisMac(gpuResidentAvailable: false)
        let held = features.isEnabled(.memoryDiscardParkedWorkspaces)
        return ParkedWorkspaceBudget(
            capacity: held ? budget.parkedWorkspaces : nil,
            idleTimeout: held && features.isEnabled(.memoryDiscardParkedIdleTimeout) ? budget.parkedIdleTimeout : nil,
            deadline: MainDeadline(owner: "ParkedWorkspaceBudget", workClass: .background, scheduler: mainDeadlines),
            memory: memoryCoordinator)
    }

    /// The page host's shared WebKit processes: at most `SubsystemBudget.webProcessPagesPerGroup`
    /// pages per process; every page of a sharing group joins with `webKitPageProcessGroups`, else only the agent pages.
    func makeWebProcessGroups() -> WebProcessGroups {
        WebProcessGroups(pagesPerProcess: SubsystemBudget.forThisMac(gpuResidentAvailable: false).webProcessPagesPerGroup,
                         groupsEverySharingPage: features.isEnabled(.webKitPageProcessGroups))
    }

    /// The one list of hidden frames with `memoryHiddenFrameLRU`: every evicted terminal's last
    /// frame, as many unlocked as this Mac's memory allows, each culled after 5 min hidden on one background deadline,
    /// all purged in the memory coordinator's release slices at a warning. Holders drop culled frames on a second
    /// background deadline, never in the turn that culled them. Nil while off.
    func makeHiddenFrameLRU() -> HiddenFrameLRU? {
        guard features.isEnabled(.memoryHiddenFrameLRU) else { return nil }
        let budget = SubsystemBudget.forThisMac(gpuResidentAvailable: false)
        return HiddenFrameLRU(
            softLimit: HiddenFrameLRU.softLimit(physicalMiB: budget.physicalMiB),
            deadline: MainDeadline(owner: "HiddenFrameLRU.cull", workClass: .background, scheduler: mainDeadlines),
            evictions: MainDeadline(owner: "HiddenFrameLRU.evict", workClass: .background, scheduler: mainDeadlines),
            memory: memoryCoordinator)
    }

    /// A window's detach of workspaces hidden past the grace with `hiddenWorkspaceDetachAfterGrace`,
    /// on one background deadline; nil while off: hidden workspaces stay in their window.
    func makeHiddenWorkspaceDetach() -> HiddenWorkspaceDetach? {
        guard features.isEnabled(.hiddenWorkspaceDetachAfterGrace) else { return nil }
        return HiddenWorkspaceDetach(
            grace: Feature.hiddenWorkspaceDetachAfterGrace.durationParam("grace") ?? .seconds(30),
            deadline: MainDeadline(owner: "HiddenWorkspaceDetach", workClass: .background, scheduler: mainDeadlines))
    }
}

// The memory histograms' discard and wake counts come from the page hibernation.
extension MemoryHistograms {
    /// The content kinds whose discards are counted: those whose discard path calls
    /// ``recordDiscard(kind:)`` through ``follow(_:agentPages:)``. Any other kind has no histogram
    /// (absent, never a measured 0) until its discard path records too.
    static let hibernationKinds = [ContentKind.browser, .agentPage].map(\.rawValue)

    /// The counted kinds: ``hibernationKinds``, overlay pages while a feature releases them (their planner,
    /// ``OverlayPageDiscards``, records each), and sidebar sections while `memoryDiscardSidebarSections` does
    /// (``SidebarSectionDiscards``).
    static func discardKinds(overlayPages: Bool, sidebarSections: Bool = false) -> [String] {
        hibernationKinds + (overlayPages ? [ContentKind.overlayPage.rawValue] : [])
            + (sidebarSections ? [ContentKind.sidebarSection.rawValue] : [])
    }

    /// Counts each page `hibernation` hibernates and each agent page `agentPages` releases as a
    /// discard of its kind, and records each woken page's time to be back.
    func follow(_ hibernation: BrowserHibernation, agentPages: AgentPageHibernation) {
        hibernation.onHibernate = { [weak self] in self?.recordDiscard(kind: ContentKind.browser.rawValue) }
        hibernation.onWakeMounted = { [weak self] in self?.recordWake($0) }
        agentPages.onRelease = { [weak self] in self?.recordDiscard(kind: ContentKind.agentPage.rawValue) }
    }
}

extension ResourceSampleSet {
    /// The browser pages' memory for the hibernation: each one's number and its sharers.
    var browserPageMemory: [String: PageMemoryReading] {
        tabMemoryReadings(kinds: TabResourceKind.browserPages).mapValues { PageMemoryReading(bytes: $0.bytes, sharers: $0.sharers) }
    }
}

// The tab cards' high-energy flags: the cache's hidden browser tabs, and Discard as the tab's Hibernate
// Tab action (its refusals, and the one path it shares with the menu and the palette).
extension HighEnergyTabMonitor: TabEnergySource {
    convenience init(cache: TabContentCache, registry: ActionRegistry, measure: @escaping SaverCPUFreeze.Measure) {
        self.init(measure: measure, hidden: { [weak cache] in cache?.lifecycle.generations(in: .mountedHidden) { cache?.browsers[$0] != nil } ?? [:] },
                  discard: { [weak registry] key in
            _ = registry?.perform("hibernateTab", invocation: ActionInvocation(target: ActionTargetRef(kind: .tab, id: key)))
        })
    }

    package func usesHighEnergy(_ tab: TabID, changed: @escaping @MainActor () -> Void) -> Bool { usesHighEnergy(tab.rawValue, changed: changed) }

    package func discard(_ tab: TabID) { discard(tab.rawValue) }
}
