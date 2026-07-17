#if os(iOS)
import CmuxMobileShell
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TaskComposerDirectoryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var remotePaths: [String] = []
    @State private var isSearchingMac = false
    @State private var searchFailure: MobileTaskDirectorySearchFailure?
    @State private var retryGeneration = 0

    private let candidates: [MobileTaskDirectoryCandidate]
    private let selectedPathID: MobileTaskDirectoryPathID
    private let select: (String) -> Void
    private let searchMac: (String) async -> Result<[String], MobileTaskDirectorySearchFailure>

    init(
        candidates: [MobileTaskDirectoryCandidate],
        selectedPath: String,
        select: @escaping (String) -> Void,
        searchMac: @escaping (String) async -> Result<[String], MobileTaskDirectorySearchFailure>
    ) {
        self.candidates = candidates
        selectedPathID = MobileTaskDirectoryPathID(path: selectedPath)
        self.select = select
        self.searchMac = searchMac
    }

    var body: some View {
        NavigationStack {
            List {
                if let searchFailure, suggestions.isEmpty, !isSearchingMac {
                    ContentUnavailableView {
                        Label(
                            L10n.string(
                                "mobile.taskComposer.directoryPicker.failure.title",
                                defaultValue: "Couldn’t Search Folders"
                            ),
                            systemImage: "exclamationmark.folder"
                        )
                    } description: {
                        Text(failureMessage(searchFailure))
                    } actions: {
                        Button(L10n.string("mobile.common.retry", defaultValue: "Retry")) {
                            retryGeneration &+= 1
                        }
                        .accessibilityIdentifier("TaskComposerDirectorySearchRetry")
                    }
                    .listRowBackground(Color.clear)
                } else if suggestions.isEmpty, !isSearchingMac {
                    ContentUnavailableView(
                        L10n.string(
                            "mobile.taskComposer.directoryPicker.empty.title",
                            defaultValue: "No Matching Folders"
                        ),
                        systemImage: "folder.badge.questionmark",
                        description: Text(
                            L10n.string(
                                "mobile.taskComposer.directoryPicker.empty.message",
                                defaultValue: "Try a folder name from another workspace or a recent task."
                            )
                        )
                    )
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(suggestions) { suggestion in
                        let displayPath = TaskComposerDirectoryDisplayPath(path: suggestion.path)
                        Button {
                            select(suggestion.path)
                            dismiss()
                        } label: {
                            TaskComposerDirectorySuggestionRow(
                                displayPath: displayPath,
                                sourceLabel: sourceLabel(for: suggestion.bestSource),
                                context: suggestion.context,
                                isSelected: suggestion.id == selectedPathID
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(displayPath.name)
                        .accessibilityValue(accessibilityValue(for: suggestion))
                        .accessibilityHint(
                            L10n.string(
                                "mobile.taskComposer.directoryPicker.result.hint",
                                defaultValue: "Uses this folder for the new workspace."
                            )
                        )
                        .accessibilityAddTraits(suggestion.id == selectedPathID ? .isSelected : [])
                    }
                }
                if isSearchingMac {
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
            }
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
            .navigationTitle(
                L10n.string(
                    "mobile.taskComposer.directoryPicker.title",
                    defaultValue: "Choose Folder"
                )
            )
            .mobileInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.string("mobile.common.cancel", defaultValue: "Cancel")) {
                        dismiss()
                    }
                }
            }
            .task(id: DirectorySearchRequest(query: query, retryGeneration: retryGeneration)) {
                await updateRemoteSuggestions()
            }
        }
    }

    private var suggestions: [MobileTaskDirectoryCandidate] {
        let remoteCandidates = remotePaths.map {
            MobileTaskDirectoryCandidate(
                path: $0,
                source: .filesystemSearch,
                context: nil
            )
        }
        return MobileTaskDirectorySuggestionIndex(candidates: candidates + remoteCandidates)
            .suggestions(matching: query)
    }

    @MainActor
    private func updateRemoteSuggestions() async {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            remotePaths = []
            isSearchingMac = false
            searchFailure = nil
            return
        }
        remotePaths = []
        searchFailure = nil
        isSearchingMac = true
        do {
            try await Task.sleep(for: .milliseconds(120))
            let result = await searchMac(trimmedQuery)
            guard !Task.isCancelled else { return }
            switch result {
            case let .success(paths):
                remotePaths = paths
                searchFailure = nil
            case .failure(.cancelled):
                remotePaths = []
                searchFailure = nil
            case let .failure(failure):
                remotePaths = []
                searchFailure = failure
            }
            isSearchingMac = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            remotePaths = []
            searchFailure = .rejected
            isSearchingMac = false
        }
    }

    private func failureMessage(_ failure: MobileTaskDirectorySearchFailure) -> String {
        switch failure {
        case .unavailable:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.unavailable",
                defaultValue: "Reconnect to this Mac, then try again."
            )
        case .timedOut:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.timeout",
                defaultValue: "This Mac took too long to search. Try again."
            )
        case .authorizationRequired:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.authorization",
                defaultValue: "Sign in again on this device and Mac, then retry."
            )
        case .rejected, .cancelled:
            L10n.string(
                "mobile.taskComposer.directoryPicker.failure.generic",
                defaultValue: "The folder search failed. Try again."
            )
        }
    }

    private func detail(for suggestion: MobileTaskDirectoryCandidate) -> String {
        [sourceLabel(for: suggestion.bestSource), suggestion.context]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func accessibilityValue(for suggestion: MobileTaskDirectoryCandidate) -> String {
        [suggestion.path, detail(for: suggestion)].formatted()
    }

    private func sourceLabel(for source: MobileTaskDirectorySource) -> String {
        switch source {
        case .filesystemSearch:
            L10n.string("mobile.taskComposer.directoryPicker.source.filesystem", defaultValue: "On this Mac")
        case .activeTerminal:
            L10n.string("mobile.taskComposer.directoryPicker.source.activeTerminal", defaultValue: "Focused terminal")
        case .activeWorkspace:
            L10n.string("mobile.taskComposer.directoryPicker.source.activeWorkspace", defaultValue: "Current workspace")
        case .templateDefault:
            L10n.string("mobile.taskComposer.directoryPicker.source.template", defaultValue: "Template default")
        case .lastSuccessful:
            L10n.string("mobile.taskComposer.directoryPicker.source.last", defaultValue: "Last used")
        case .openWorkspace, .openTerminal:
            L10n.string("mobile.taskComposer.directoryPicker.source.open", defaultValue: "Open on this Mac")
        case .recentSuccessful:
            L10n.string("mobile.taskComposer.directoryPicker.source.recent", defaultValue: "Recent task")
        case .home:
            L10n.string("mobile.taskComposer.directoryPicker.source.home", defaultValue: "Home folder")
        }
    }
}

private struct DirectorySearchRequest: Hashable {
    let query: String
    let retryGeneration: Int
}
#endif
