import CmuxSettings
import SwiftUI

/// Root view of the settings window, hosted in an AppKit-owned
/// `NSWindow` by the app's `SettingsWindowFactory` (cmux issue
/// #7777; a SwiftUI `Window` scene's `openWindow(id:)` could
/// silently no-op and strand the open path).
///
/// Composes a single tall `ScrollView` of stacked sections — the
/// legacy in-app layout — with a left sidebar that scrolls to a
/// section's anchor on click. Owns the search query, the scroll
/// proxy, and the section anchors.
@MainActor
public struct SettingsWindowRoot: View {
    let runtime: SettingsRuntime
    private let searchIndex: SettingsSearchIndex
    /// Section a targeted show asked for, when the host knew it at window
    /// creation. It is mounted first, and the restore navigation posted on
    /// appear follows it instead of the persisted last-viewed section, so a
    /// `cmux settings open <target>` never builds the previous pane.
    let initialSection: SettingsSectionID?
    /// Progressive mounting of the detail sections (cmux issue #12134):
    /// the section the window opens on is built in the first layout pass,
    /// the rest one per update pass. Window-scoped like the scroll state.
    @State var mountModel: SettingsSectionMountModel

    static let selectedSectionDefaultsKey = "selectedSettingsSection"
    static let cloudMachinesBetaDefaultsKey = "cloud.beta.machines.enabled"

    /// - Parameters:
    ///   - runtime: Catalog, stores, and host actions shared by every section.
    ///   - initialSection: Section mounted in the first layout pass; `nil`
    ///     restores the last-viewed section the sidebar persists.
    ///   - mountModel: Mount model driving the progressive build. Supply one
    ///     to steer or observe mounting from outside the view; by default one
    ///     is built for `initialSection`.
    public init(
        runtime: SettingsRuntime,
        initialSection: SettingsSectionID? = nil,
        mountModel: SettingsSectionMountModel? = nil
    ) {
        self.runtime = runtime
        self.searchIndex = runtime.searchIndex
        self.initialSection = initialSection
        // The `@AppStorage` properties below read the same store; the restore
        // target has to be known before the first body evaluation because
        // that pass runs inside `NSWindow(contentViewController:)`.
        let defaults = UserDefaults.standard
        let restoredSection = defaults.string(forKey: Self.selectedSectionDefaultsKey)
            .flatMap(SettingsSectionID.init(rawValue:)) ?? .account
        let cloudAvailable = !ManagedDevicePolicy().isEnforced(.disableCloud)
            && (runtime.hostActions.isCloudMachinesAvailable
            || defaults.bool(forKey: Self.cloudMachinesBetaDefaultsKey)
            )
        _mountModel = State(initialValue: mountModel ?? SettingsSectionMountModel(
            initial: initialSection ?? restoredSection,
            order: Self.mountOrder(cloudAvailable: cloudAvailable)
        ))
    }

    @State private var cloudDisabledByPolicy = ManagedDevicePolicy().isEnforced(.disableCloud)
    @State private var searchText: String = ""
    // Legacy SettingsRootView persists two distinct pieces of state:
    // `selectedSettingsSection` (the top-level section pane shown in
    // the detail) and `selectedSettingsSidebarEntry` (the specific
    // sidebar row that's highlighted — a section row, a setting hit
    // from the search index, etc.). Keeping them separate matters
    // because under search the user can click an individual setting
    // hit and we still want the section pane to follow, but two
    // sibling hits inside one section must each be selectable.
    // @AppStorage (not @SceneStorage): the window is AppKit-hosted, so
    // there is no SwiftUI scene to store into (cmux issue #7777).
    @AppStorage(SettingsWindowRoot.selectedSectionDefaultsKey) private var selectedSectionRaw: String = SettingsSectionID.account.rawValue
    @AppStorage("selectedSettingsSidebarEntry") private var selectedSidebarEntryID: String = "section:\(SettingsSectionID.account.rawValue)"
    // Mirrors BetaFeaturesCatalogSection.cloudMachines so flipping the Beta
    // Features toggle shows/hides the Cloud sidebar row without reopening
    // Settings; the host folds in the remote rollout flag.
    @AppStorage(SettingsWindowRoot.cloudMachinesBetaDefaultsKey) private var cloudMachinesBetaEnabled = false
    // Legacy `SettingsRootView` binds `NavigationSplitView`'s
    // `columnVisibility` so the user can collapse the sidebar via the
    // toolbar button (or the SidebarCommands menu) and have that state
    // persist for the lifetime of the window. Without a binding,
    // `NavigationSplitView` is locked to whatever its initial layout
    // resolved to, which makes the chevron toggle a no-op in the
    // package window. Keep this in @State (not @SceneStorage) because
    // legacy stores it on the transient `SettingsDraftState`, not in
    // SceneStorage.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    // Mirrors legacy SettingsView.settingsNavigationGeneration. When
    // multiple navigation requests fire in quick succession (e.g. the
    // sidebar selection changes plus an external app.cmux.settings
    // navigation post), each `proxy.scrollTo(...)` runs one main-actor
    // hop later. Without a generation guard, a stale earlier request can
    // win and snap the scroll back to a section the user has already
    // moved past. The counter is incremented in `applyScrollNavigation`
    // and re-checked inside the scheduled `Task { @MainActor in ... }`,
    // so only the most recent request actually scrolls.
    @State var settingsNavigationGeneration: Int = 0
    // Drives the "flash the navigated-to row" affordance the legacy
    // settings window had. When the user clicks a search hit, the target
    // row pulses an accent border for a few seconds so the eye can find
    // it after the scroll. `token` changes on every highlight so
    // re-navigating to the same row restarts the pulse; `startedAt`
    // seeds the row's `TimelineView` fade. Read by every
    // `SettingsCardRow` through `\.settingsSearchHighlightState`.
    @State private var searchHighlight = SettingsSearchHighlightState(anchorID: nil, token: 0, startedAt: nil)

    var defaultsStore: UserDefaultsSettingsStore { runtime.userDefaultsStore }
    var jsonStore: JSONConfigStore { runtime.jsonStore }
    var secretStore: SecretFileStore { runtime.secretStore }
    var catalog: SettingCatalog { runtime.catalog }
    var hostActions: SettingsHostActions { runtime.hostActions }
    var accountFlow: AccountFlow? { runtime.accountFlow }
    /// Whether the Cloud section (and its sidebar row) is offered at all: the
    /// remote rollout flag or the Beta Features opt-in makes its surfaces
    /// real, and the `DisableCloud` managed policy wins over both.
    var isCloudSectionAvailable: Bool {
        !cloudDisabledByPolicy && (hostActions.isCloudMachinesAvailable || cloudMachinesBetaEnabled)
    }

    /// Resolves the selected section pane from the persisted raw value,
    /// defaulting to ``SettingsSectionID/account`` when the stored value
    /// is unrecognized (e.g., after dropping a case).
    private var selectedSection: SettingsSectionID {
        SettingsSectionID(rawValue: selectedSectionRaw) ?? .account
    }

    /// Whether the user currently has a non-empty search query. When
    /// false the sidebar should track section selection only; when true
    /// the per-entry selection survives.
    private var isSearching: Bool { !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // Legacy uses a non-optional `Binding<String>` because a sidebar
    // selection always points at *some* entry (section row or setting
    // hit). Mirroring that here lets List's selection semantics behave
    // identically — particularly that clicking the same row again
    // doesn't transiently nil-out the selection and break SceneStorage
    // round-trips.
    private var sidebarSelectionBinding: Binding<String> {
        Binding<String>(
            get: { self.selectedSidebarEntryID },
            set: { newValue in
                self.selectSidebarEntry(newValue)
            }
        )
    }

    public var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
        } detail: {
            detailScroll
        }
        .navigationSplitViewStyle(.balanced)
        // Inject the built search index so each SettingsCardRow can map
        // its declared cmux.json paths to scroll/highlight anchor ids,
        // and publish the active highlight so the matching row pulses.
        .environment(\.settingsSearchIndex, searchIndex)
        .environment(\.settingsSearchHighlightState, searchHighlight)
        // Legacy SettingsRootView pins the window minimum to
        // SettingsWindowPresenter.minimumSize (820 x 540); mirror that
        // so the package window can shrink to the same lower bound.
        .frame(minWidth: 820, minHeight: 540)
        .settingsErrorAlert(log: runtime.errorLog)
        .task {
            let signals = ManagedDevicePolicy.changeSignals()
            cloudDisabledByPolicy = ManagedDevicePolicy().isEnforced(.disableCloud)
            // A profile installed before this window opened: the persisted
            // selection may still point at the hidden Cloud section.
            leaveCloudSectionIfDisabledByPolicy()
            for await _ in signals {
                cloudDisabledByPolicy = ManagedDevicePolicy().isEnforced(.disableCloud)
                leaveCloudSectionIfDisabledByPolicy()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.navigationRequestName)) { notification in
            applyNavigationRequest(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: Self.sidebarToggleRequestName)) { _ in
            // AppKit hosts this window, so SwiftUI's SidebarCommands cannot
            // reach the split view; the host app routes its sidebar-toggle
            // menu command here when the Settings window is key.
            columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
        }
        .onChange(of: searchText) { _, newValue in
            // Legacy SettingsRootView resyncs the sidebar entry to the
            // section row whenever the search text is cleared, so
            // typing then clearing doesn't leave a stale "deep" entry
            // selected.
            guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            selectedSidebarEntryID = sectionEntryID(for: selectedSection)
        }
    }

    public static let navigationRequestName = Notification.Name("cmux.settings.navigate")
    public static let sidebarToggleRequestName = Notification.Name("cmux.settings.toggleSidebar")

    /// Legacy `SettingsRootView.onReceive` only updates the selection
    /// state (sidebar entry + section pane) in response to an external
    /// navigation request. The actual scroll-to is owned by
    /// `SettingsView`, which listens to the same notification and
    /// translates it into `proxy.scrollTo(...)` calls. The package
    /// follows the same split: state changes happen here; the detail
    /// scroll picks up the notification on its own and scrolls.
    private func applyNavigationRequest(_ notification: Notification) {
        guard
            let rawValue = notification.userInfo?["target"] as? String,
            let target = SettingsSectionID(rawValue: rawValue)
        else { return }
        // Legacy preserves the highlighted search hit when an external
        // navigation request resolves to the same section the currently
        // selected sidebar entry already lives in. Without this, typing
        // a search query and clicking a setting hit would have the
        // sidebar selection collapsed back to the section row whenever
        // anyone (re)posted a navigation request to that section.
        let selectedEntry = searchIndex.entries.first { $0.id == selectedSidebarEntryID }
        let selectedEntryTarget = parentSection(for: selectedSidebarEntryID)
        let shouldPreserveSearchSelection = isSearching
            && selectedEntry != nil
            && selectedEntryTarget == target
        navigate(to: target, preferSectionSelection: !shouldPreserveSearchSelection)
    }

    /// Moves a selection that rests on the Cloud section (hidden under
    /// `DisableCloud`) to Account, both at first render and on a transition.
    private func leaveCloudSectionIfDisabledByPolicy() {
        if cloudDisabledByPolicy {
            // If the Cloud slot is the outstanding progressive mount, its
            // intentionally empty content has no onAppear to advance the
            // queue. Skip it explicitly so later sections still mount.
            _ = mountModel.skip(.cloudMachines)
        }
        if cloudDisabledByPolicy && selectedSection == .cloudMachines {
            navigate(to: .account)
        }
    }

    private func isEntryVisible(_ entry: SettingsSearchIndex.Entry) -> Bool {
        guard !isCloudSectionAvailable else { return true }
        switch entry.kind {
        case .section:
            return entry.id != "section:\(SettingsSectionID.cloudMachines.rawValue)"
        case .setting(let parent):
            return parent != .cloudMachines
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        List(selection: sidebarSelectionBinding) {
            let matches = sidebarEntries(matching: searchText).filter { isEntryVisible($0) }
            if matches.isEmpty {
                Text(String(localized: "settings.search.noResults", defaultValue: "No Results"))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(matches) { entry in
                    SettingsSidebarEntryRow(
                        title: entry.title,
                        symbolName: entry.symbolName,
                        subtitle: subtitle(for: entry)
                    )
                    .tag(entry.id)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
        .searchable(text: $searchText, placement: .sidebar, prompt: Text(String(localized: "settings.search.prompt", defaultValue: "Search")))
        .navigationSplitViewColumnWidth(210)
    }

    func sidebarEntries(matching query: String) -> [SettingsSearchIndex.Entry] { searchIndex.match(query) }

    /// Legacy `SettingsSearchEntry` populates `subtitle` with the
    /// parent section's title for setting-type hits and `nil` for
    /// section-type hits, so `SettingsSidebarEntryRow` renders the
    /// section name underneath each search hit but keeps section
    /// rows single-line. Mirror that here.
    private func subtitle(for entry: SettingsSearchIndex.Entry) -> String? {
        switch entry.kind {
        case .section:
            return nil
        case .setting(let parent):
            return parent.title
        }
    }

    /// Updates both the sidebar entry selection and the underlying
    /// section pane based on the clicked sidebar row. Setting-hit
    /// clicks keep the deep entry selected (so the row stays
    /// highlighted) while still moving the detail pane to the parent
    /// section.
    ///
    /// Mirrors legacy `SettingsRootView.selectSidebarEntry`: in
    /// addition to updating selection state, it posts a settings
    /// navigation notification so any external listeners (host-side
    /// code, other windows) and the package's own detail scroll
    /// receive a consistent stream of navigation events. The detail
    /// scroll picks up the same notification and turns it into a
    /// `proxy.scrollTo(...)` so every click — including repeat clicks
    /// or sibling search hits — drives a scroll.
    private func selectSidebarEntry(_ entryID: String) {
        // Mirror legacy `SettingsRootView.selectSidebarEntry`: bail if
        // the entry id doesn't resolve to a known search-index entry,
        // so stale SceneStorage values or out-of-band selection writes
        // can't corrupt the section pane. The lookup also resolves the
        // entry's target section in one place rather than re-parsing
        // the id string.
        let index = searchIndex
        guard let entry = index.entries.first(where: { $0.id == entryID }) else { return }
        selectedSidebarEntryID = entry.id
        let section = parentSection(for: entry)
        if selectedSectionRaw != section.rawValue {
            selectedSectionRaw = section.rawValue
        }
        postNavigationRequest(target: section, anchorID: entry.anchorID, highlight: isSearching)
    }

    /// Maps a resolved search-index entry to its target section,
    /// matching legacy `SettingsSearchEntry.target` semantics. Section
    /// entries decode their target from the canonical "section:<raw>"
    /// id; setting entries carry their parent directly on the kind.
    private func parentSection(for entry: SettingsSearchIndex.Entry) -> SettingsSectionID {
        switch entry.kind {
        case .section:
            return parentSection(for: entry.id)
        case .setting(let parent):
            return parent
        }
    }

    /// Posts a `cmux.settings.navigate` notification with the same
    /// userInfo shape legacy `SettingsNavigationRequest.post` uses,
    /// so host-side listeners and the package's own detail scroll
    /// receive a consistent stream of navigation events.
    private func postNavigationRequest(
        target: SettingsSectionID,
        anchorID: String,
        highlight: Bool
    ) {
        NotificationCenter.default.post(
            name: Self.navigationRequestName,
            object: nil,
            userInfo: [
                "target": target.rawValue,
                "anchor": anchorID,
                "highlight": highlight
            ]
        )
    }

    /// Navigates from outside (e.g., a `cmux.settings.navigate`
    /// notification) to a top-level section, also resetting the sidebar
    /// row to that section's header row when `preferSectionSelection`
    /// is true. Legacy passes `false` when the navigation request
    /// arrives while the user is searching and the request target
    /// matches the currently selected setting hit — so the highlighted
    /// sidebar row stays put while the detail pane snaps to the
    /// section.
    private func navigate(to target: SettingsSectionID, preferSectionSelection: Bool = true) {
        if selectedSectionRaw != target.rawValue { selectedSectionRaw = target.rawValue }
        if preferSectionSelection {
            let sectionEntry = sectionEntryID(for: target)
            if selectedSidebarEntryID != sectionEntry { selectedSidebarEntryID = sectionEntry }
        }
    }

    /// The canonical entry ID the search index uses for section header
    /// rows ("section:<rawValue>"). Mirrors ``SettingsSearchIndex``'s
    /// internal id scheme.
    private func sectionEntryID(for section: SettingsSectionID) -> String {
        "section:\(section.rawValue)"
    }

    /// Decodes an entry ID back to the section pane that should be
    /// scrolled into view. Section rows resolve to themselves; setting
    /// hits resolve to their parent section.
    private func parentSection(for entryID: String) -> SettingsSectionID {
        if entryID.hasPrefix("section:") {
            let raw = String(entryID.dropFirst("section:".count))
            return SettingsSectionID(rawValue: raw) ?? .account
        }
        if let entry = searchIndex.entries.first(where: { $0.id == entryID }) {
            if case .setting(let parent) = entry.kind { return parent }
        }
        return .account
    }

    @ViewBuilder
    private var detailScroll: some View {
        GeometryReader { _ in
            ScrollViewReader { proxy in
                ScrollView {
                    // Eager VStack (not LazyVStack) on purpose: search
                    // navigation must `scrollTo` any row, including ones in
                    // a section currently off-screen. A LazyVStack only
                    // registers a row's `.id` once its section is realized,
                    // so `scrollTo(deepRow)` silently no-ops while that
                    // section is scrolled away, stranding the user at the
                    // top. Every mounted section keeps its anchors
                    // addressable; sections still mounting (issue #12134)
                    // hold a placeholder slot with the section anchor, and
                    // navigation into one mounts it before scrolling.
                    VStack(alignment: .leading, spacing: 14) {
                        sectionStack(proxy: proxy)
                    }
                    // Legacy SettingsView only pads the inner VStack; it
                    // does not pin maxWidth. Adding an outer frame would
                    // change the alignment math the legacy layout assumes
                    // (SettingsCard widths come from the ScrollView, not
                    // from a parent VStack stretched to topLeading).
                    .padding(.horizontal, 20)
                    .padding(.top, 20)
                    .padding(.bottom, 20)
                }
                .toggleStyle(.switch)
                .onAppear {
                    // Legacy SettingsView.onAppear scrolls to the restored
                    // section so reopening the Settings window lands on
                    // the last-viewed pane rather than always at Account.
                    // Posting through the navigation notification keeps a
                    // single scroll path (legacy `applySettingsNavigation`)
                    // while restored setting hits resolve through the
                    // immutable index. Fallback hits collapse to sections.
                    // A targeted open restores to its target instead: the
                    // host posts that same navigation one hop later, and
                    // restoring the last-viewed pane first would mount it
                    // for nothing (issue #12134).
                    let section = initialSection ?? selectedSection
                    let anchor: String
                    if let initialSection {
                        anchor = anchorID(for: initialSection)
                    } else if selectedSidebarEntryID.isEmpty {
                        anchor = sectionEntryID(for: section)
                    } else {
                        anchor = searchIndex.entries.first { $0.id == selectedSidebarEntryID }?.anchorID ?? selectedSidebarEntryID
                    }
                    postNavigationRequest(
                        target: section,
                        anchorID: anchor,
                        highlight: false
                    )
                }
                .onReceive(NotificationCenter.default.publisher(for: Self.navigationRequestName)) { notification in
                    applyScrollNavigation(notification, proxy: proxy)
                }
            }
        }
    }

    /// Mirrors legacy `SettingsView.applySettingsNavigation`: scrolls
    /// to the section header first, then — when the navigation request
    /// carries a deep anchor and `highlight` is set — scrolls that
    /// specific anchor into the vertical center of the viewport.
    ///
    /// Section-level navigation posts (e.g. external `navigate(to:)`
    /// calls that don't carry a meaningful highlight) only get the
    /// section-top scroll, matching the legacy snap-to-top behavior.
    ///
    /// A monotonically increasing `settingsNavigationGeneration`
    /// guards against stale scrolls when navigation requests pile up:
    /// each call captures the current generation, increments it, and
    /// the scheduled scroll only runs if the captured generation is
    /// still the latest — otherwise an earlier request would clobber
    /// the user's most recent navigation.
    private func applyScrollNavigation(_ notification: Notification, proxy: ScrollViewProxy) {
        guard
            let rawValue = notification.userInfo?["target"] as? String,
            let target = SettingsSectionID(rawValue: rawValue)
        else { return }
        let anchorID = (notification.userInfo?["anchor"] as? String) ?? self.anchorID(for: target)
        let shouldHighlight = (notification.userInfo?["highlight"] as? Bool) ?? false
        let sectionID = self.anchorID(for: target)
        settingsNavigationGeneration += 1
        let navigationGeneration = settingsNavigationGeneration
        // Arm (or clear) the highlight before the scroll so the pulse is
        // already live when the target lands in view. A section hit
        // (anchorID == sectionID) highlights the section header; a row
        // hit highlights that row. Mirrors legacy applySettingsNavigation.
        if shouldHighlight {
            searchHighlight = SettingsSearchHighlightState(
                anchorID: anchorID,
                token: searchHighlight.token + 1,
                startedAt: Date()
            )
        } else {
            searchHighlight = SettingsSearchHighlightState(
                anchorID: nil,
                token: searchHighlight.token,
                startedAt: nil
            )
        }
        // One scroll, one target. A section hit pins its header to the
        // top; a row hit centers the row. Sections mount progressively
        // (issue #12134): the pin keeps the viewport on this target while
        // sections above it grow out of their placeholders, and a target
        // that is still a placeholder is mounted now and scrolled to from
        // its `onAppear`, once its row ids exist. For a mounted target the
        // hop off the current update is a main-actor `Task` (not
        // `DispatchQueue.main.async`, which package policy forbids): it
        // lets the highlight-state mutation above commit before the scroll
        // and is generation-guarded so a newer navigation still wins.
        let anchor: UnitPoint = anchorID == sectionID ? .top : .center
        let scrollTarget = SettingsSectionScrollTarget(
            section: target,
            anchorID: anchorID,
            anchor: anchor,
            generation: navigationGeneration
        )
        mountModel.pin(scrollTarget)
        guard mountModel.ensureMounted(target) else {
            mountModel.deferScroll(scrollTarget)
            return
        }
        mountModel.cancelDeferredScroll()
        Task { @MainActor in
            guard navigationGeneration == settingsNavigationGeneration else { return }
            proxy.scrollTo(anchorID, anchor: anchor)
        }
    }
}
