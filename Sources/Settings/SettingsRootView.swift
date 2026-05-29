import AppKit
import SwiftUI
import Observation
import Darwin
import Bonsplit
import UniformTypeIdentifiers

struct SettingsRootView: View {
    @Bindable var draftState: SettingsDraftState
    @SceneStorage("selectedSettingsSection") private var selectedSectionRaw = SettingsNavigationTarget.account.rawValue
    @SceneStorage("selectedSettingsSidebarEntry") private var selectedSidebarEntryID = SettingsSearchIndex.defaultSelectionID

    private var selectedSection: SettingsNavigationTarget {
        SettingsNavigationTarget(rawValue: selectedSectionRaw) ?? .account
    }

    private var sidebarEntries: [SettingsSearchEntry] {
        SettingsSearchIndex.entries(matching: draftState.settingsSearchText)
    }

    private var isSearching: Bool {
        !draftState.settingsSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var sidebarSelection: Binding<String> {
        Binding(
            get: { selectedSidebarEntryID },
            set: { selectSidebarEntry($0) }
        )
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $draftState.settingsColumnVisibility) {
            List(selection: sidebarSelection) {
                if sidebarEntries.isEmpty {
                    Text(String(localized: "settings.search.noResults", defaultValue: "No Results"))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(sidebarEntries) { entry in
                        SettingsSidebarEntryRow(entry: entry)
                            .tag(entry.id)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationTitle(String(localized: "settings.title", defaultValue: "Settings"))
            .searchable(
                text: $draftState.settingsSearchText,
                placement: .sidebar,
                prompt: Text(String(localized: "settings.search.prompt", defaultValue: "Search"))
            )
            .navigationSplitViewColumnWidth(210)
        } detail: {
            SettingsView(draftState: draftState)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: SettingsWindowPresenter.minimumSize.width, minHeight: SettingsWindowPresenter.minimumSize.height)
        .onChange(of: draftState.settingsSearchText) { _, newValue in
            guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            selectedSidebarEntryID = SettingsSearchIndex.sectionID(for: selectedSection)
        }
        .onAppear {
            if let target = SettingsWindowPresenter.consumePendingNavigationTarget() {
                navigate(to: target, postRequest: true)
            } else {
                navigate(to: selectedSection, postRequest: true)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SettingsNavigationRequest.notificationName)) { notification in
            guard let target = SettingsNavigationRequest.target(from: notification) else { return }
            let selectedEntry = SettingsSearchIndex.entry(withID: selectedSidebarEntryID)
            let shouldPreserveSearchSelection = isSearching && selectedEntry?.target == target
            navigate(to: target, preferSectionSelection: !shouldPreserveSearchSelection, postRequest: false)
        }
    }

    private func selectSidebarEntry(_ entryID: String) {
        guard let entry = SettingsSearchIndex.entry(withID: entryID) else { return }
        selectedSidebarEntryID = entry.id
        selectedSectionRaw = entry.target.rawValue
        SettingsNavigationRequest.post(entry.target, anchorID: entry.id, highlight: isSearching)
    }

    private func navigate(
        to target: SettingsNavigationTarget,
        preferSectionSelection: Bool = true,
        postRequest: Bool
    ) {
        selectedSectionRaw = target.rawValue
        if preferSectionSelection {
            selectedSidebarEntryID = SettingsSearchIndex.sectionID(for: target)
        }
        if postRequest {
            SettingsNavigationRequest.post(target)
        }
    }
}
