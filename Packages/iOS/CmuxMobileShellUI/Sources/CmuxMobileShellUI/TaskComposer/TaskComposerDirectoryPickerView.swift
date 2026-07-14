#if os(iOS)
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

struct TaskComposerDirectoryPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var remotePaths: [String] = []
    @State private var isSearchingMac = false

    private let candidates: [MobileTaskDirectoryCandidate]
    private let selectedPathID: MobileTaskDirectoryPathID
    private let select: (String) -> Void
    private let searchMac: (String) async -> [String]

    init(
        candidates: [MobileTaskDirectoryCandidate],
        selectedPath: String,
        select: @escaping (String) -> Void,
        searchMac: @escaping (String) async -> [String]
    ) {
        self.candidates = candidates
        selectedPathID = MobileTaskDirectoryPathID(path: selectedPath)
        self.select = select
        self.searchMac = searchMac
    }

    var body: some View {
        NavigationStack {
            List {
                if suggestions.isEmpty, !isSearchingMac {
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
                        Button {
                            select(suggestion.path)
                            dismiss()
                        } label: {
                            TaskComposerDirectorySuggestionRow(
                                suggestion: suggestion,
                                detail: detail(for: suggestion),
                                isSelected: suggestion.id == selectedPathID
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(suggestion.path)
                        .accessibilityValue(detail(for: suggestion))
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
            .task(id: query) {
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
            return
        }
        remotePaths = []
        isSearchingMac = true
        do {
            try await Task.sleep(for: .milliseconds(120))
            let paths = await searchMac(trimmedQuery)
            guard !Task.isCancelled else { return }
            remotePaths = paths
            isSearchingMac = false
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            remotePaths = []
            isSearchingMac = false
        }
    }

    private func detail(for suggestion: MobileTaskDirectoryCandidate) -> String {
        [sourceLabel(for: suggestion.bestSource), suggestion.context]
            .compactMap { $0 }
            .joined(separator: " · ")
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

private struct TaskComposerDirectorySuggestionRow: View {
    let suggestion: MobileTaskDirectoryCandidate
    let detail: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(suggestion.path)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if isSelected {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
#endif
