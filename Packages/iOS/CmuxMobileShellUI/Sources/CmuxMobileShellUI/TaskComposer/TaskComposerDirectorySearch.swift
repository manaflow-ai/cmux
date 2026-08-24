#if os(iOS)
import CmuxMobileRPC
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// The remote-search state one picker screen owns. Every screen of the picker
/// exposes the same Mac-wide folder search, so the hub and each browse level
/// hold one of these next to their query text.
struct TaskComposerDirectorySearchState: Equatable {
    var response: MobileTaskDirectorySearchResponse?
    var failure: MobileTaskDirectorySearchFailure?
    var isSearching = false
    var retryGeneration = 0

    var statusMessage: String? {
        guard let response else { return nil }
        if response.truncated {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.search.truncated",
                defaultValue: "More indexed folders match. Refine your search to see them."
            )
        }
        if response.searchScope != .allIndexedVolumes {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.search.limited",
                defaultValue: "This Mac returned limited search results. Browse to reach every accessible folder."
            )
        }
        if !response.gatheringComplete {
            return L10n.string(
                "mobile.taskComposer.directoryPicker.search.partial",
                defaultValue: "The Mac search index did not finish in time. Refine your search or retry."
            )
        }
        return nil
    }

    /// Remote matches first, then local suggestions, deduplicated by exact
    /// path bytes.
    func mergedResults(
        matching query: String,
        from index: MobileTaskDirectorySuggestionIndex
    ) -> [MobileTaskDirectoryCandidate] {
        let remote = (response?.directories ?? []).map {
            MobileTaskDirectoryCandidate(path: $0, source: .filesystemSearch, context: nil)
        }
        var seen = Set<MobileTaskDirectoryPathID>()
        return (remote + index.suggestions(matching: query)).filter { seen.insert($0.id).inserted }
    }
}

extension View {
    /// Runs the debounced Mac folder search whenever `query` (or a retry)
    /// changes, writing results into `state`.
    func taskComposerDirectorySearch(
        _ state: Binding<TaskComposerDirectorySearchState>,
        query: String,
        searchMac: @escaping (
            String
        ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>,
        debounceClock: any Clock<Duration> = ContinuousClock()
    ) -> some View {
        modifier(TaskComposerDirectorySearchDriver(
            state: state,
            query: query,
            searchMac: searchMac,
            debounceClock: debounceClock
        ))
    }
}

private struct TaskComposerDirectorySearchDriver: ViewModifier {
    @Binding var state: TaskComposerDirectorySearchState
    let query: String
    let searchMac: (
        String
    ) async -> Result<MobileTaskDirectorySearchResponse, MobileTaskDirectorySearchFailure>
    let debounceClock: any Clock<Duration>

    private struct Request: Hashable {
        let query: String
        let retryGeneration: Int
    }

    func body(content: Content) -> some View {
        content.task(id: Request(query: query, retryGeneration: state.retryGeneration)) {
            await run()
        }
    }

    @MainActor
    private func run() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            state.response = nil
            state.failure = nil
            state.isSearching = false
            return
        }
        state.response = nil
        state.failure = nil
        state.isSearching = true
        do {
            // The cancellable delay is the search debounce itself, not
            // synchronization; the clock is injectable so tests control it.
            try await debounceClock.sleep(for: .milliseconds(140))
            let result = await searchMac(trimmedQuery)
            guard !Task.isCancelled else { return }
            switch result {
            case let .success(response):
                state.response = response
                state.failure = nil
            case .failure(.cancelled):
                state.response = nil
                state.failure = nil
            case let .failure(failure):
                state.response = nil
                state.failure = failure
            }
            state.isSearching = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            state.response = nil
            state.failure = .rejected
            state.isSearching = false
        }
    }
}

/// The search-results rows a picker screen shows inside its `List` while a
/// query is active. Empty, failed, and in-flight states with no rows render
/// through ``TaskComposerDirectorySearchStatusOverlay`` instead.
struct TaskComposerDirectorySearchResultsSections: View {
    let results: [MobileTaskDirectoryCandidate]
    let selectedPathID: MobileTaskDirectoryPathID
    let isSearching: Bool
    let failure: MobileTaskDirectorySearchFailure?
    let statusMessage: String?
    let choose: (String) -> Void

    var body: some View {
        if !results.isEmpty {
            Section {
                ForEach(results) { suggestion in
                    TaskComposerDirectorySearchResultButton(
                        suggestion: suggestion,
                        isSelected: suggestion.id == selectedPathID,
                        choose: choose
                    )
                }
                if isSearching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(
                            L10n.string(
                                "mobile.taskComposer.directoryPicker.searching",
                                defaultValue: "Searching this Mac…"
                            )
                        )
                        .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(
                        L10n.string(
                            "mobile.taskComposer.directoryPicker.search.coverage",
                            defaultValue: "Search checks the Mac’s indexed folders and scans its home folder live. Browse to reach restricted locations."
                        )
                    )
                    if let statusMessage {
                        Text(statusMessage)
                            .accessibilityIdentifier("MobileTaskDirectorySearchStatus")
                    }
                    if let failure {
                        Text(failure.pickerMessage)
                    }
                }
            }
        }
    }
}

private struct TaskComposerDirectorySearchResultButton: View {
    let suggestion: MobileTaskDirectoryCandidate
    let isSelected: Bool
    let choose: (String) -> Void

    var body: some View {
        Button {
            choose(suggestion.path)
        } label: {
            TaskComposerDirectorySuggestionRow(
                displayPath: TaskComposerDirectoryDisplayPath(path: suggestion.path),
                sourceLabel: suggestion.bestSource.pickerLabel,
                isSelected: isSelected
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(TaskComposerDirectoryDisplayPath(path: suggestion.path).name)
        .accessibilityValue(accessibilityValue)
        .accessibilityHint(
            L10n.string(
                "mobile.taskComposer.directoryPicker.result.hint",
                defaultValue: "Uses this folder for the new workspace."
            )
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var accessibilityValue: String {
        let detail = [
            suggestion.bestSource.pickerLabel,
            suggestion.context,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
        return [suggestion.path, detail].formatted()
    }
}

/// Full-area search states: the spinner before first results, the no-matches
/// placeholder, and the failed-search placeholder with retry.
struct TaskComposerDirectorySearchStatusOverlay: View {
    let state: TaskComposerDirectorySearchState
    let hasResults: Bool
    let retry: () -> Void

    var body: some View {
        if !hasResults {
            if state.isSearching {
                ProgressView(
                    L10n.string(
                        "mobile.taskComposer.directoryPicker.searching",
                        defaultValue: "Searching this Mac…"
                    )
                )
            } else if let failure = state.failure {
                ContentUnavailableView {
                    Label(
                        L10n.string(
                            "mobile.taskComposer.directoryPicker.failure.title",
                            defaultValue: "Couldn’t Search Folders"
                        ),
                        systemImage: "exclamationmark.magnifyingglass"
                    )
                } description: {
                    Text(failure.pickerMessage)
                } actions: {
                    Button(L10n.string("mobile.common.retry", defaultValue: "Retry"), action: retry)
                        .accessibilityIdentifier("TaskComposerDirectorySearchRetry")
                }
            } else {
                ContentUnavailableView {
                    Label(
                        L10n.string(
                            "mobile.taskComposer.directoryPicker.search.empty.title",
                            defaultValue: "No Matching Folders"
                        ),
                        systemImage: "folder.badge.questionmark"
                    )
                } description: {
                    Text(
                        L10n.string(
                            "mobile.taskComposer.directoryPicker.search.empty.message",
                            defaultValue: "Nothing matched in the Mac’s index or home folder. Browse to look elsewhere, and check that cmux on the Mac can access its files."
                        )
                    )
                }
            }
        }
    }
}
#endif
