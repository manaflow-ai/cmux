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
/// - each workspace's agent-runtime changes (task status);
/// - the agent-chat session registry's sidebar changes (`agents`);
/// - surface focus and live-agent-index notifications.
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
    /// When ``revision`` last bumped. A sidebar that doesn't read `clock`
    /// builds its `clock` key from this instead of wall time, so an
    /// unchanged context stays equal and renderers skip it.
    private(set) var changedAt = Date()

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

    private func start() {
        guard let tabManager else { return }
        changes
            .receive(on: DispatchQueue.main)
            .coalesceLatest(for: Self.coalesceInterval, scheduler: DispatchQueue.main)
            .sink { [weak self] in self?.noteChange() }
            .store(in: &cancellables)

        tabManager.objectWillChange
            .sink { [weak self] _ in self?.changes.send() }
            .store(in: &cancellables)
        tabManager.tabsPublisher
            .sink { [weak self] tabs in self?.observeWorkspaces(tabs) }
            .store(in: &cancellables)

        let center = NotificationCenter.default
        Publishers.Merge(
            center.publisher(for: .ghosttyDidFocusSurface),
            center.publisher(for: .sharedLiveAgentIndexDidChange)
        )
        .sink { [weak self] _ in self?.changes.send() }
        .store(in: &cancellables)

        if let service = TerminalController.shared.agentChatTranscriptService {
            let stream = service.sidebarChanges()
            globalTasks.append(Task { @MainActor [weak self] in
                for await _ in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.changes.send()
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
            let runtimeChanges = workspace.sidebarAgentRuntimeObservation.changes()
            workspaceTasks.append(Task { @MainActor [weak self] in
                for await _ in runtimeChanges {
                    guard let self, !Task.isCancelled else { return }
                    self.changes.send()
                }
            })
        }
        Publishers.MergeMany(publishers)
            .sink { [weak self] in self?.changes.send() }
            .store(in: &workspaceCancellables)
    }

    private func noteChange() {
        revision &+= 1
        changedAt = Date()
    }
}

/// Answers ``CustomSidebarRefreshPolicy`` for a sidebar file, re-reading the
/// file only when its modification date changes.
///
/// The loaded file is resolved by name and may switch between `.swift`,
/// `.json` and `.js` across reloads, so every candidate with the same base
/// name is checked.
@MainActor
final class CustomSidebarRefreshPolicyCache {
    static let shared = CustomSidebarRefreshPolicyCache()

    private struct Entry {
        let modificationDates: [Date?]
        let policy: CustomSidebarRefreshPolicy
    }

    private static let candidateExtensions = ["swift", "json", "js"]
    private var entries: [URL: Entry] = [:]
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func policy(fileURL: URL, sourceOverride: String?) -> CustomSidebarRefreshPolicy {
        if let sourceOverride {
            return CustomSidebarRefreshPolicy.policy(forSource: sourceOverride)
        }
        let base = fileURL.deletingPathExtension()
        let candidates = Self.candidateExtensions.map { base.appendingPathExtension($0) }
        let dates = candidates.map { url in
            (try? fileManager.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        }
        if let entry = entries[base], entry.modificationDates == dates {
            return entry.policy
        }
        let sources = zip(candidates, dates).compactMap { url, date -> String? in
            guard date != nil else { return nil }
            return try? String(contentsOf: url, encoding: .utf8)
        }
        let policy = CustomSidebarRefreshPolicy.policy(forSources: sources)
        entries[base] = Entry(modificationDates: dates, policy: policy)
        return policy
    }
}

/// Feeds a custom sidebar surface its data context, rebuilding it once a
/// second only when the sidebar reads `clock`, and otherwise only when
/// ``CustomSidebarDataChangeMonitor`` reports a change (plus the safety
/// rebuild every ``CustomSidebarRefreshPolicy/fallbackInterval``).
///
/// Changes the enclosing view already observes (for the main sidebar, the
/// tab manager and unread snapshot) still re-render immediately, because the
/// content closure re-runs with the parent.
struct CustomSidebarLiveDataReader<Content: View>: View {
    let fileURL: URL
    let sourceOverride: String?
    let monitor: CustomSidebarDataChangeMonitor
    let build: (_ clockDate: Date, _ refreshDate: Date) -> [String: SwiftValue]
    let content: ([String: SwiftValue]) -> Content
    @State private var holdsMonitor = false

    /// - Parameter build: Builds the data context. `clockDate` feeds the
    ///   `clock` key; `refreshDate` changes on every rebuild request
    ///   (including the safety rebuild), for callers that cache contexts.
    init(
        fileURL: URL,
        sourceOverride: String? = nil,
        monitor: CustomSidebarDataChangeMonitor,
        build: @escaping (_ clockDate: Date, _ refreshDate: Date) -> [String: SwiftValue],
        @ViewBuilder content: @escaping ([String: SwiftValue]) -> Content
    ) {
        self.fileURL = fileURL
        self.sourceOverride = sourceOverride
        self.monitor = monitor
        self.build = build
        self.content = content
    }

    var body: some View {
        // Read here so a coalesced change re-runs this body.
        let changedAt = monitor.changedAt
        // The outer schedule re-checks the file's policy every fallback
        // interval, so editing a sidebar to start or stop reading `clock`
        // switches its schedule within a few seconds.
        TimelineView(.periodic(from: .now, by: CustomSidebarRefreshPolicy.fallbackInterval)) { fallback in
            switch CustomSidebarRefreshPolicyCache.shared.policy(fileURL: fileURL, sourceOverride: sourceOverride) {
            case .everySecond:
                TimelineView(.periodic(from: .now, by: CustomSidebarRefreshPolicy.clockInterval)) { timeline in
                    // Whole seconds, so panes ticking in the same second
                    // share one cached context.
                    content(build(timeline.date, timeline.date.flooredToWholeSecond))
                }
            case .onDataChange:
                content(build(changedAt, max(changedAt, fallback.date)))
            }
        }
        .onAppear {
            guard !holdsMonitor else { return }
            holdsMonitor = true
            monitor.retain()
        }
        .onDisappear {
            guard holdsMonitor else { return }
            holdsMonitor = false
            monitor.release()
        }
    }
}

private extension Date {
    var flooredToWholeSecond: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }
}
