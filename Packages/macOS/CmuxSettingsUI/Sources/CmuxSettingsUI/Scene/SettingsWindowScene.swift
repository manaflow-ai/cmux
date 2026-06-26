import CmuxSettings
import SwiftUI

/// The settings window SwiftUI `Scene`.
///
/// Composes a single tall `ScrollView` of stacked sections — the
/// legacy in-app layout — with a left sidebar that scrolls to a
/// section's anchor on click. This mirrors what cmux's settings
/// window has historically looked like; using a `NavigationSplitView`
/// with one-pane-at-a-time selection was a previous (now reverted)
/// architecture choice.
@MainActor
public struct SettingsWindowScene: Scene {
    private let runtime: SettingsRuntime

    public init(runtime: SettingsRuntime) {
        self.runtime = runtime
    }

    public var body: some Scene {
        WindowGroup(String(localized: "settings.title", defaultValue: "Settings"), id: "cmux.settings") {
            SettingsWindowRoot(runtime: runtime)
                .settingsRuntime(runtime)
        }
        .defaultSize(width: 980, height: 680)
        .windowResizability(.contentMinSize)
        .commands { SidebarCommands() }
    }
}

/// Root view of the settings window. Owns the search query, the
/// scroll proxy, and the section anchors. Renders sidebar + tall
/// scrolling content side-by-side.
@MainActor
public struct SettingsWindowRoot: View {
    private let runtime: SettingsRuntime
    private let searchIndex: SettingsSearchIndex

    public init(runtime: SettingsRuntime) {
        self.runtime = runtime
        self.searchIndex = runtime.searchIndex
    }

    @State private var searchText: String = ""
    // Legacy SettingsRootView persists two distinct pieces of state:
    // `selectedSettingsSection` (the top-level section pane shown in
    // the detail) and `selectedSettingsSidebarEntry` (the specific
    // sidebar row that's highlighted — a section row, a setting hit
    // from the search index, etc.). Keeping them separate matters
    // because under search the user can click an individual setting
    // hit and we still want the section pane to follow, but two
    // sibling hits inside one section must each be selectable.
    @SceneStorage("selectedSettingsSection") private var selectedSectionRaw: String = SettingsSectionID.account.rawValue
    @SceneStorage("selectedSettingsSidebarEntry") private var selectedSidebarEntryID: String = "section:\(SettingsSectionID.account.rawValue)"
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
    @State private var settingsNavigationGeneration: Int = 0
    // Drives the "flash the navigated-to row" affordance the legacy
    // settings window had. When the user clicks a search hit, the target
    // row pulses an accent border for a few seconds so the eye can find
    // it after the scroll. `token` changes on every highlight so
    // re-navigating to the same row restarts the pulse; `startedAt`
    // seeds the row's `TimelineView` fade. Read by every
    // `SettingsCardRow` through `\.settingsSearchHighlightState`.
    @State private var searchHighlight = SettingsSearchHighlightState(anchorID: nil, token: 0, startedAt: nil)

    private var defaultsStore: UserDefaultsSettingsStore { runtime.userDefaultsStore }
    private var jsonStore: JSONConfigStore { runtime.jsonStore }
    private var secretStore: SecretFileStore { runtime.secretStore }
    private var catalog: SettingCatalog { runtime.catalog }
    private var hostActions: SettingsHostActions { runtime.hostActions }
    private var accountFlow: AccountFlow? { runtime.accountFlow }

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
        .onReceive(NotificationCenter.default.publisher(for: Self.navigationRequestName)) { notification in
            applyNavigationRequest(notification)
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

    @ViewBuilder
    private var sidebar: some View {
        List(selection: sidebarSelectionBinding) {
            let matches = sidebarEntries(matching: searchText)
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
                    // top. Building all ~14 sections up front keeps every
                    // anchor addressable for a single, reliable scroll.
                    VStack(alignment: .leading, spacing: 14) {
                        sectionStack
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
                    let section = selectedSection
                    let anchor = selectedSidebarEntryID.isEmpty
                        ? sectionEntryID(for: section)
                        : searchIndex.entries.first { $0.id == selectedSidebarEntryID }?.anchorID ?? selectedSidebarEntryID
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
        // One scroll, one target. The detail stack is eager (see
        // `detailScroll`), so every row's `.id` is always registered and a
        // single `scrollTo` resolves any anchor regardless of where the
        // viewport currently sits — no "realize the section first" dance.
        // A section hit pins its header to the top; a row hit centers the
        // row. The hop off the current update is a main-actor `Task` (not
        // `DispatchQueue.main.async`, which package policy forbids): it
        // lets the highlight-state mutation above commit before the scroll
        // and is generation-guarded so a newer navigation still wins.
        let anchor: UnitPoint = anchorID == sectionID ? .top : .center
        Task { @MainActor in
            guard navigationGeneration == settingsNavigationGeneration else { return }
            proxy.scrollTo(anchorID, anchor: anchor)
        }
    }

    @ViewBuilder
    private var sectionStack: some View {
        // Order matches the legacy in-app SettingsView scroll order with
        // Appearance inserted after Account as the visual-settings hub:
        // Account, Appearance, App, Terminal, TextBox, Mobile, Sidebar,
        // Beta Features, Automation, Browser (with embedded Import),
        // Global Hotkey, Keyboard Shortcuts, Workspace Colors, cmux.json, Reset.
        AccountSection(
            defaultsStore: defaultsStore,
            catalog: catalog,
            accountFlow: accountFlow
        )
        .id(anchorID(for: .account))

        AppearanceSection(
            defaultsStore: defaultsStore,
            catalog: catalog,
            hostActions: hostActions
        )
        .id(anchorID(for: .appearance))

        AppSection(
            defaultsStore: defaultsStore,
            catalog: catalog,
            hostActions: hostActions
        )
        .id(anchorID(for: .app))

        TerminalSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog,
            hostActions: hostActions
        )
        .id(anchorID(for: .terminal))

        TextBoxSection(defaultsStore: defaultsStore, catalog: catalog)
            .id(anchorID(for: .textBox))

        SleepyModeSection(hostActions: hostActions, store: hostActions.sleepyModeStore())
            .id(anchorID(for: .sleepyMode))

        MobileSection(defaultsStore: defaultsStore, catalog: catalog, hostActions: hostActions)
            .id(anchorID(for: .mobile))

        SidebarSection(defaultsStore: defaultsStore, catalog: catalog)
            .id(anchorID(for: .sidebarAppearance))

        CustomSidebarsSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog,
            errorLog: runtime.errorLog
        )
        .id(anchorID(for: .customSidebars))

        BetaFeaturesSection(defaultsStore: defaultsStore, catalog: catalog)
            .id(anchorID(for: .betaFeatures))

        AutomationSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            secretStore: secretStore,
            catalog: catalog,
            errorLog: runtime.errorLog
        )
        .id(anchorID(for: .automation))

        BrowserSection(
            defaultsStore: defaultsStore,
            catalog: catalog,
            hostActions: hostActions,
            importAnchorID: anchorID(for: .browserImport)
        )
        .id(anchorID(for: .browser))

        GlobalHotkeySection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog,
            errorLog: runtime.errorLog
        )
        .id(anchorID(for: .globalHotkey))

        KeyboardShortcutsSection(
            jsonStore: jsonStore,
            catalog: catalog,
            errorLog: runtime.errorLog,
            hostActions: hostActions
        )
        .id(anchorID(for: .keyboardShortcuts))

        WorkspaceColorsSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog,
            errorLog: runtime.errorLog
        )
        .id(anchorID(for: .workspaceColors))

        SettingsJSONSection(jsonStore: jsonStore, hostActions: hostActions)
            .id(anchorID(for: .settingsJSON))

        ResetSection(
            defaultsStore: defaultsStore,
            jsonStore: jsonStore,
            catalog: catalog
        )
        .id(anchorID(for: .reset))
    }

    private func anchorID(for section: SettingsSectionID) -> String {
        "section:\(section.rawValue)"
    }
}
