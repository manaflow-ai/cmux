#if os(iOS)
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// One pushed level of the directory browser. Each folder gets its own screen
/// so the standard back button walks up the hierarchy, and choosing happens
/// through the pinned confirm button at the bottom.
struct TaskComposerDirectoryBrowseScreen: View {
    let requestedPath: String
    let selectedPathID: MobileTaskDirectoryPathID
    let suggestionIndex: MobileTaskDirectorySuggestionIndex
    let recents: [MobileTaskDirectoryCandidate]
    let choose: (String) -> Void
    let cancel: () -> Void
    let searchMac: (
        String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>
    let listMac: (
        _ path: String,
        _ offset: Int
    ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>

    @State private var browse: TaskComposerDirectoryBrowseState
    @State private var query = ""
    @State private var search = TaskComposerDirectorySearchState()

    init(
        requestedPath: String,
        selectedPathID: MobileTaskDirectoryPathID,
        suggestionIndex: MobileTaskDirectorySuggestionIndex,
        recents: [MobileTaskDirectoryCandidate],
        choose: @escaping (String) -> Void,
        cancel: @escaping () -> Void,
        searchMac: @escaping (
            String
        ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>,
        listMac: @escaping (
            _ path: String,
            _ offset: Int
        ) async -> Result<MobileTaskDirectoryListResponse, MobileTaskDirectoryListFailure>
    ) {
        self.requestedPath = requestedPath
        self.selectedPathID = selectedPathID
        self.suggestionIndex = suggestionIndex
        self.recents = recents
        self.choose = choose
        self.cancel = cancel
        self.searchMac = searchMac
        self.listMac = listMac
        _browse = State(initialValue: TaskComposerDirectoryBrowseState(initialPath: requestedPath))
    }

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
                folderSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(displayName)
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
        .taskComposerRecentChipsBar(recents: recents, isVisible: !isSearchActive)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isSearchActive, let currentPath = browse.snapshot?.currentPath {
                TaskComposerDirectoryChooseButton(
                    folderName: displayName,
                    choose: { choose(currentPath) }
                )
            }
        }
        .overlay { statusOverlay }
        .taskComposerDirectorySearch($search, query: query, searchMac: searchMac)
        .task(id: browse.pendingRequest) {
            await loadPendingDirectoryRequest()
        }
    }

    @ViewBuilder
    private var folderSection: some View {
        let entries = browse.snapshot?.entries ?? []
        if !entries.isEmpty {
            Section {
                ForEach(entries, id: \.path) { entry in
                    NavigationLink(value: TaskComposerDirectoryBrowseDestination(path: entry.path)) {
                        TaskComposerDirectoryFolderRow(entry: entry)
                    }
                    .disabled(!entry.isReadable)
                    .onAppear {
                        if entry.path == entries.last?.path {
                            browse.requestNextPage()
                        }
                    }
                    .accessibilityLabel(entry.name)
                    .accessibilityValue(entry.path)
                    .accessibilityHint(
                        entry.isReadable
                            ? L10n.string(
                                "mobile.taskComposer.directoryPicker.browse.open.hint",
                                defaultValue: "Shows the folders inside this folder."
                            )
                            : MobileTaskDirectoryListFailure.unreadable.pickerMessage
                    )
                }
                if browse.snapshot?.nextOffset != nil {
                    TaskComposerDirectoryLoadMoreRow(
                        appendFailure: appendFailure,
                        retry: { browse.retryFailedRequest() }
                    )
                }
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(browse.displayPath)
                        .fontDesign(.monospaced)
                    if let totalCount = browse.snapshot?.totalCount, totalCount > 0 {
                        Text(Self.folderCount(totalCount))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusOverlay: some View {
        if isSearchActive {
            TaskComposerDirectorySearchStatusOverlay(
                state: search,
                hasResults: !searchResults.isEmpty,
                retry: { search.retryGeneration &+= 1 }
            )
        } else if let failure = replaceFailure {
            ContentUnavailableView {
                Label(
                    failure.pickerTitle,
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(failure.pickerMessage)
            } actions: {
                Button(L10n.string("mobile.common.retry", defaultValue: "Retry")) {
                    browse.retryFailedRequest()
                }
                .accessibilityIdentifier("TaskComposerDirectoryBrowseRetry")
            }
        } else if browse.isLoading, browse.snapshot == nil {
            ProgressView(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.browse.loading",
                    defaultValue: "Loading folders…"
                )
            )
        } else if let snapshot = browse.snapshot, snapshot.entries.isEmpty {
            ContentUnavailableView(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.browse.empty.title",
                    defaultValue: "No Subfolders"
                ),
                systemImage: "folder",
                description: Text(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.empty.message",
                        defaultValue: "You can still use this folder for the new workspace."
                    )
                )
            )
        }
    }

    private var isSearchActive: Bool {
        !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var searchResults: [MobileTaskDirectoryCandidate] {
        search.mergedResults(matching: query, from: suggestionIndex)
    }

    private var replaceFailure: MobileTaskDirectoryListFailure? {
        guard let failure = browse.failure, failure.request.kind == .replace else { return nil }
        return failure.reason
    }

    private var appendFailure: MobileTaskDirectoryListFailure? {
        guard let failure = browse.failure, failure.request.kind == .append else { return nil }
        return failure.reason
    }

    private var displayName: String {
        let path = browse.displayPath
        if path == "/" {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.browse.computer",
                defaultValue: "Computer"
            )
        }
        if path == "~" {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.browse.home",
                defaultValue: "Home"
            )
        }
        let name = TaskComposerDirectoryDisplayPath(path: path).name
        return name.isEmpty ? path : name
    }

    private static func folderCount(_ count: Int) -> String {
        if count == 1 {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.browse.folderCountFormat.one",
                defaultValue: "1 folder"
            )
        }
        return String(
            format: L10n.string(
                "mobile.taskComposer.directoryPicker.browse.folderCountFormat.other",
                defaultValue: "%d folders"
            ),
            count
        )
    }

    @MainActor
    private func loadPendingDirectoryRequest() async {
        guard let request = browse.pendingRequest else {
            // A pop/push transition can cancel the only in-flight load. When
            // the screen reappears fully idle and empty, request the folder
            // again instead of showing a permanently blank listing.
            if browse.snapshot == nil, browse.failure == nil {
                browse.navigate(to: requestedPath)
            }
            return
        }
        let result = await listMac(request.path, request.offset)
        guard !Task.isCancelled else {
            browse.cancel(request)
            return
        }
        browse.resolve(result, for: request)
    }
}

/// The tail row of a paged folder listing: a spinner while the next page
/// loads automatically, or the append failure with an inline retry.
private struct TaskComposerDirectoryLoadMoreRow: View {
    let appendFailure: MobileTaskDirectoryListFailure?
    let retry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if appendFailure != nil {
                Label(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.more.failure.title",
                        defaultValue: "Couldn’t Load More Folders"
                    ),
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button(L10n.string("mobile.common.retry", defaultValue: "Retry"), action: retry)
                    .buttonStyle(.borderless)
                    .accessibilityIdentifier("TaskComposerDirectoryBrowseRetry")
            } else {
                ProgressView()
                Text(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.browse.loading",
                        defaultValue: "Loading folders…"
                    )
                )
                .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
#endif
