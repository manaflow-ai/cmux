#if os(iOS)
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The task composer's folder picker: a navigation stack whose root lists
/// suggested folders and browse locations, with one pushed screen per folder
/// level. It opens pre-navigated to the selected folder so the back button
/// walks up that folder's ancestry, mirroring the system Files picker.
struct TaskComposerDirectoryPickerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var path: [TaskComposerDirectoryBrowseDestination]

    private let suggested: [MobileTaskDirectoryCandidate]
    private let suggestionIndex: MobileTaskDirectorySuggestionIndex
    private let selectedPath: String
    private let selectedPathID: MobileTaskDirectoryPathID
    private let select: (String) -> Void
    private let searchMac: (
        String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>
    private let listMac: (
        _ path: String,
        _ offset: Int
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>

    init(
        candidates: [MobileTaskDirectoryCandidate],
        selectedPath: String,
        select: @escaping (String) -> Void,
        searchMac: @escaping (
            String
        ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>,
        listMac: @escaping (
            _ path: String,
            _ offset: Int
        ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>
    ) {
        let index = MobileTaskDirectorySuggestionIndex(candidates: candidates)
        suggestionIndex = index
        suggested = index.suggestions(matching: "", limit: 6)
        self.selectedPath = selectedPath
        selectedPathID = MobileTaskDirectoryPathID(path: selectedPath)
        self.select = select
        self.searchMac = searchMac
        self.listMac = listMac
        _path = State(
            initialValue: TaskComposerDirectoryBrowseDestination.ancestry(for: selectedPath)
        )
    }

    var body: some View {
        NavigationStack(path: $path) {
            TaskComposerDirectoryLocationsScreen(
                suggested: suggested,
                suggestionIndex: suggestionIndex,
                selectedPath: selectedPath,
                selectedPathID: selectedPathID,
                choose: choose,
                cancel: { dismiss() },
                searchMac: searchMac
            )
            .navigationDestination(for: TaskComposerDirectoryBrowseDestination.self) { destination in
                TaskComposerDirectoryBrowseScreen(
                    requestedPath: destination.path,
                    selectedPathID: selectedPathID,
                    suggestionIndex: suggestionIndex,
                    choose: choose,
                    cancel: { dismiss() },
                    searchMac: searchMac,
                    listMac: listMac
                )
            }
        }
    }

    private func choose(_ path: String) {
        select(path)
        dismiss()
    }
}

/// The picker's root: suggested folders and the browse entry points.
private struct TaskComposerDirectoryLocationsScreen: View {
    let suggested: [MobileTaskDirectoryCandidate]
    let suggestionIndex: MobileTaskDirectorySuggestionIndex
    let selectedPath: String
    let selectedPathID: MobileTaskDirectoryPathID
    let choose: (String) -> Void
    let cancel: () -> Void
    let searchMac: (
        String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>

    @State private var query = ""
    @State private var search = TaskComposerDirectorySearchState()

    var body: some View {
        List {
            if isSearchActive {
                TaskComposerDirectorySearchResultsSections(
                    results: searchResults,
                    selectedPathID: selectedPathID,
                    isSearching: search.isSearching,
                    failure: searchResults.isEmpty ? nil : search.failure,
                    statusMessage: search.statusMessage,
                    choose: choose
                )
            } else {
                suggestedSection
                locationsSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(
            L10n.string(
                "mobile.taskComposer.directoryPicker.title",
                defaultValue: "Choose Folder"
            )
        )
        .mobileInlineNavigationTitle()
        .searchable(
            text: $query,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: Text(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.search",
                    defaultValue: "Search folders"
                )
            )
        )
        .toolbar {
            TaskComposerDirectoryCancelToolbar(cancel: cancel)
        }
        .overlay {
            if isSearchActive {
                TaskComposerDirectorySearchStatusOverlay(
                    state: search,
                    hasResults: !searchResults.isEmpty,
                    retry: { search.retryGeneration &+= 1 }
                )
            }
        }
        .taskComposerDirectorySearch($search, query: query, searchMac: searchMac)
    }

    @ViewBuilder
    private var suggestedSection: some View {
        if !suggested.isEmpty {
            Section(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.sections.suggested",
                    defaultValue: "Suggested"
                )
            ) {
                ForEach(suggested) { candidate in
                    TaskComposerDirectorySuggestedButton(
                        candidate: candidate,
                        isSelected: candidate.id == selectedPathID,
                        choose: choose
                    )
                }
            }
        }
    }

    private var locationsSection: some View {
        Section(
            L10n.string(
                "mobile.taskComposer.directoryPicker.sections.locations",
                defaultValue: "Locations"
            )
        ) {
            if showsSelectedLocation {
                NavigationLink(value: TaskComposerDirectoryBrowseDestination(path: selectedPath)) {
                    TaskComposerDirectorySuggestionRow(
                        displayPath: TaskComposerDirectoryDisplayPath(path: selectedPath),
                        sourceLabel: nil,
                        isSelected: false
                    )
                }
                .accessibilityIdentifier("MobileTaskDirectoryBrowseCurrent")
            }
            NavigationLink(value: TaskComposerDirectoryBrowseDestination(path: "~")) {
                Label(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.home",
                        defaultValue: "Home"
                    ),
                    systemImage: "house.fill"
                )
            }
            .accessibilityIdentifier("MobileTaskDirectoryBrowseHome")
            NavigationLink(value: TaskComposerDirectoryBrowseDestination(path: "/")) {
                Label(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.computer",
                        defaultValue: "Computer"
                    ),
                    systemImage: "internaldrive.fill"
                )
            }
            .accessibilityIdentifier("MobileTaskDirectoryBrowseComputer")
        }
    }

    private var showsSelectedLocation: Bool {
        let trimmed = selectedPath.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != "~" && trimmed != "/"
    }

    private var isSearchActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [MobileTaskDirectoryCandidate] {
        search.mergedResults(matching: query, from: suggestionIndex)
    }
}

private struct TaskComposerDirectorySuggestedButton: View {
    let candidate: MobileTaskDirectoryCandidate
    let isSelected: Bool
    let choose: (String) -> Void

    var body: some View {
        Button {
            choose(candidate.path)
        } label: {
            TaskComposerDirectorySuggestionRow(
                displayPath: TaskComposerDirectoryDisplayPath(path: candidate.path),
                sourceLabel: candidate.bestSource.pickerLabel,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TaskComposerDirectoryDisplayPath(path: candidate.path).name)
        .accessibilityValue(candidate.path)
        .accessibilityHint(
            L10n.string(
                "mobile.taskComposer.directoryPicker.result.hint",
                defaultValue: "Uses this folder for the new workspace."
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The trailing Cancel button every picker screen shows, dismissing the sheet
/// from any depth of the browse stack.
struct TaskComposerDirectoryCancelToolbar: ToolbarContent {
    let cancel: () -> Void

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel"), action: cancel)
                .accessibilityIdentifier("MobileTaskDirectoryPickerCancel")
        }
    }
}

/// The pinned confirm action of a browse screen.
struct TaskComposerDirectoryChooseButton: View {
    let folderName: String
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            Text(
                String(
                    format: L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.useFormat",
                        defaultValue: "Use “%@”"
                    ),
                    folderName
                )
            )
            .fontWeight(.semibold)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .contentShape(.capsule)
        }
        .mobileGlassProminentButton()
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .accessibilityIdentifier("MobileTaskDirectoryBrowseUseCurrent")
    }
}
#endif
