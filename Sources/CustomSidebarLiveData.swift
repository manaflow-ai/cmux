import CmuxNotifications
import CmuxSidebar
import CmuxSwiftRender
import Combine
import Foundation
import Observation
import SwiftUI

/// Signals when anything a custom sidebar's data context reads may have
/// changed, for one window's ``TabManager``.
///
/// Custom sidebars used to rebuild their whole data context and re-render
/// once a second from a `TimelineView`, which kept the main thread 47-98%
/// busy with ~50 workspaces (issue #46725). This monitor lets a sidebar that
/// doesn't read `clock` rebuild only after a change instead.
///
/// No single existing publisher covers every input of
/// `Workspace.customSidebarWorkspaceSnapshot`, so the monitor merges:
/// - the tab manager's `objectWillChange` (tabs, selection, groups);
/// - each workspace's `objectWillChange` (`@Published` fields such as titles,
///   pins, colors, group ids, panel titles and per-surface ports);
/// - each workspace's sidebar observation publishers (sidebar metadata:
///   git, pull requests, progress, prompts, remote state);
/// - each workspace's agent-runtime changes (task status), through the
///   passive publisher so row subscribers keep their replay;
/// - the agent-chat session registry's sidebar changes (`agents`);
/// - surface focus and live-agent-index notifications.
///
/// Some of these also fire for fields no sidebar shows (remote heartbeats,
/// for example). That costs at most one rebuild per coalesce window: the
/// rebuilt context is equal, and every renderer skips an equal context.
///
/// Bursts are coalesced to at most one ``revision`` bump per second, the
/// same ceiling the old tick had, with the first change after an idle period
/// delivered on the next main-queue turn. Inputs with no signal at all are
/// covered by the sidebar's ``CustomSidebarRefreshPolicy/fallbackInterval``
/// rebuild. Subscriptions run only while a sidebar holds the monitor (see
/// ``retain()``).
@MainActor
@Observable
final class CustomSidebarDataChangeMonitor {
    /// Bumps after each coalesced change. Views read it to re-render.
    private(set) var revision: UInt64 = 0
    /// When ``revision`` last bumped.
    private(set) var changedAt = Date()
    /// The window's cache of which sidebar files read `clock`.
    @ObservationIgnored let refreshPolicies = CustomSidebarRefreshPolicyCache()

    @ObservationIgnored private weak var tabManager: TabManager?
    @ObservationIgnored private var retainCount = 0
    @ObservationIgnored private let changes = PassthroughSubject<Void, Never>()
    @ObservationIgnored private var cancellables: [AnyCancellable] = []
    @ObservationIgnored private var workspaceCancellables: [AnyCancellable] = []
    @ObservationIgnored private var workspaceTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var globalTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var observedWorkspaceIds: [UUID] = []

    static let coalesceInterval: DispatchQueue.SchedulerTimeType.Stride = .seconds(1)

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    /// Starts observing on the first holder.
    func retain() {
        retainCount += 1
        if retainCount == 1 {
            start()
        }
    }

    /// Stops observing when the last holder releases.
    func release() {
        guard retainCount > 0 else { return }
        retainCount -= 1
        if retainCount == 0 {
            stop()
        }
    }

    /// True while at least one sidebar holds the monitor.
    var isObserving: Bool { retainCount > 0 }

    private func signal() {
        changes.send()
    }

    private func start() {
        guard let tabManager else { return }
        changes
            .receive(on: DispatchQueue.main)
            .coalesceLatest(for: Self.coalesceInterval, scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.noteChange() }
            .store(in: &cancellables)

        tabManager.objectWillChange
            .sink { [weak self] _ in self?.signal() }
            .store(in: &cancellables)
        tabManager.tabsPublisher
            .sink { [weak self] tabs in self?.observeWorkspaces(tabs) }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        Publishers.Merge(
            center.publisher(for: .ghosttyDidFocusSurface),
            center.publisher(for: .sharedLiveAgentIndexDidChange)
        )
        .sink { [weak self] _ in self?.signal() }
        .store(in: &cancellables)

        if let service = TerminalController.shared.agentChatTranscriptService {
            // Each `sidebarChanges()` stream is its own subscriber; its
            // subscribe-time yield doesn't consume anything shared.
            let stream = service.sidebarChanges()
            globalTasks.append(Task { @MainActor [weak self] in
                for await _ in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.signal()
                }
            })
        }
    }

    private func stop() {
        cancellables.removeAll()
        workspaceCancellables.removeAll()
        workspaceTasks.forEach { $0.cancel() }
        workspaceTasks.removeAll()
        globalTasks.forEach { $0.cancel() }
        globalTasks.removeAll()
        observedWorkspaceIds = []
    }

    private func observeWorkspaces(_ tabs: [Workspace]) {
        let ids = tabs.map(\.id)
        guard ids != observedWorkspaceIds else { return }
        observedWorkspaceIds = ids
        workspaceCancellables.removeAll()
        workspaceTasks.forEach { $0.cancel() }
        workspaceTasks.removeAll()
        guard !tabs.isEmpty else { return }

        var publishers: [AnyPublisher<Void, Never>] = []
        publishers.reserveCapacity(tabs.count * 3)
        for workspace in tabs {
            publishers.append(workspace.objectWillChange.map { _ in () }.eraseToAnyPublisher())
            publishers.append(workspace.sidebarImmediateObservationPublisher)
            publishers.append(workspace.sidebarObservationPublisher)
            let runtimeChanges = workspace.sidebarAgentRuntimeObservation.passiveChanges()
            workspaceTasks.append(Task { @MainActor [weak self] in
                for await _ in runtimeChanges {
                    guard let self, !Task.isCancelled else { return }
                    self.signal()
                }
            })
        }
        Publishers.MergeMany(publishers)
            .sink { [weak self] in self?.signal() }
            .store(in: &workspaceCancellables)
    }

    private func noteChange() {
        revision &+= 1
        changedAt = Date()
        #if DEBUG
        cmuxDebugLog("customSidebar.monitor.bump revision=\(revision)")
        #endif
    }
}

/// Feeds a custom sidebar surface its data context, rebuilding it once a
/// second only when the sidebar reads `clock`, and otherwise only when
/// ``CustomSidebarDataChangeMonitor`` reports a change (plus the safety
/// rebuild every ``CustomSidebarRefreshPolicy/fallbackInterval``).
///
/// A sidebar that doesn't read `clock` gets a `clock` fixed at mount time,
/// so a rebuild with unchanged data produces an equal context and the
/// renderers skip it. Changes the enclosing view already observes (for the
/// main sidebar, the tab manager and unread snapshot) still re-render
/// immediately, because the content closure re-runs with the parent.
struct CustomSidebarLiveDataReader<Content: View>: View {
    let fileURL: URL
    let sourceOverride: String?
    let monitor: CustomSidebarDataChangeMonitor
    let unreadSource: SidebarUnreadModel?
    let build: (_ clockDate: Date, _ refreshDate: Date) -> [String: SwiftValue]
    let content: ([String: SwiftValue]) -> Content
    @State private var heldMonitor: CustomSidebarDataChangeMonitor?
    @State private var fixedClockDate = Date()

    /// - Parameters:
    ///   - unreadSource: Unread model the `build` closure reads, when the
    ///     enclosing view doesn't already observe it; read here so unread
    ///     changes re-render this view.
    ///   - build: Builds the data context. `clockDate` feeds the `clock`
    ///     key; `refreshDate` changes on every rebuild request (including
    ///     the safety rebuild), for callers that cache contexts.
    init(
        fileURL: URL,
        sourceOverride: String? = nil,
        monitor: CustomSidebarDataChangeMonitor,
        unreadSource: SidebarUnreadModel? = nil,
        build: @escaping (_ clockDate: Date, _ refreshDate: Date) -> [String: SwiftValue],
        @ViewBuilder content: @escaping ([String: SwiftValue]) -> Content
    ) {
        self.fileURL = fileURL
        self.sourceOverride = sourceOverride
        self.monitor = monitor
        self.unreadSource = unreadSource
        self.build = build
        self.content = content
    }

    var body: some View {
        // Read here so a coalesced change or an unread change re-runs this
        // body.
        let changedAt = monitor.changedAt
        let _ = unreadSource?.snapshot
        let fixedClockDate = fixedClockDate
        // The outer schedule is the safety rebuild, and re-checks the
        // file's policy, so editing a sidebar to start or stop reading
        // `clock` switches its tick within a few seconds. The inner view is
        // the same in both policies (only its interval changes), so a
        // policy flip doesn't remount the surface.
        // Both schedules start from the fixed mount date, not `.now`: a new
        // start date on every re-render would hand TimelineView a different
        // schedule each time and force an extra update.
        TimelineView(.periodic(from: fixedClockDate, by: CustomSidebarRefreshPolicy.fallbackInterval)) { fallback in
            let policy = monitor.refreshPolicies.policy(fileURL: fileURL, sourceOverride: sourceOverride)
            TimelineView(Self.tickSchedule(for: policy, fixedClockDate: fixedClockDate)) { timeline in
                switch policy {
                case .everySecond:
                    #if DEBUG
                    let _ = cmuxDebugLog("customSidebar.reader.build policy=everySecond")
                    #endif
                    // Whole seconds, so panes ticking in the same second
                    // share one cached context.
                    content(build(timeline.date, timeline.date.flooredToWholeSecond))
                case .onDataChange:
                    #if DEBUG
                    let _ = cmuxDebugLog("customSidebar.reader.build policy=onDataChange")
                    #endif
                    content(build(
                        fixedClockDate,
                        max(changedAt, fallback.date.flooredTo(CustomSidebarRefreshPolicy.fallbackInterval))
                    ))
                }
            }
        }
        .onAppear { hold(monitor) }
        .onChange(of: ObjectIdentifier(monitor)) { _, _ in hold(monitor) }
        .onDisappear { hold(nil) }
    }

    /// The inner tick: every second for `clock` (started from now, as the
    /// old tick was), effectively never otherwise (the outer safety rebuild
    /// and data changes drive it, so its start stays fixed).
    private static func tickSchedule(
        for policy: CustomSidebarRefreshPolicy,
        fixedClockDate: Date
    ) -> PeriodicTimelineSchedule {
        switch policy {
        case .everySecond:
            .periodic(from: .now, by: CustomSidebarRefreshPolicy.clockInterval)
        case .onDataChange:
            .periodic(from: fixedClockDate, by: 24 * 60 * 60)
        }
    }

    /// Keeps exactly one retain on the monitor this view currently shows.
    private func hold(_ next: CustomSidebarDataChangeMonitor?) {
        guard heldMonitor !== next else { return }
        heldMonitor?.release()
        next?.retain()
        heldMonitor = next
    }
}

private extension Date {
    var flooredToWholeSecond: Date {
        flooredTo(1)
    }

    /// Floors to a multiple of `interval`, so views ticking on the same
    /// interval agree on the refresh key.
    func flooredTo(_ interval: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 / interval).rounded(.down) * interval)
    }
}
