import CmuxMobileShell
import CmuxMobileSupport
import SwiftUI

/// Search-first project picker. Typing fuzzy-searches every directory the Mac
/// has indexed; an empty query offers recent project folders plus browse roots
/// that can reach ANY directory level by level. Permission problems surface
/// inline and never dead-end the picker.
struct DispatchProjectPickerScreen: View {
    @Bindable var picker: DispatchProjectPickerModel
    let composer: DispatchComposerModel
    let select: (String) -> Void
    let browse: (String) -> Void

    @FocusState private var searchFocused: Bool

    /// Selection is a plain closure call: the picker deliberately uses its own
    /// search field instead of `.searchable`, whose active presentation
    /// swallows NavigationStack pops (verified live on iOS 26).
    private func handleSelect(_ directory: String) {
        select(directory)
    }

    var body: some View {
        List {
            if picker.trimmedQuery.isEmpty {
                suggestedSection
                browseRootsSection
            } else {
                searchResultsSection
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .top, spacing: 0) {
            searchField
        }
        .navigationTitle(L10n.string("mobile.dispatch.picker.title", defaultValue: "Project"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                hiddenFoldersMenu
            }
        }
        .onAppear {
            searchFocused = true
        }
        .accessibilityIdentifier("MobileDispatchProjectPicker")
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField(searchPrompt, text: $picker.query)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .focused($searchFocused)
                .submitLabel(.search)
                .accessibilityIdentifier("MobileDispatchPickerSearchField")
            if !picker.query.isEmpty {
                Button {
                    picker.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string("mobile.dispatch.picker.clearSearch", defaultValue: "Clear search"))
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DispatchStyle.cardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(DispatchStyle.hairline, lineWidth: 0.5)
        )
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(DispatchStyle.screenBackground.opacity(0.94))
    }

    private var searchPrompt: String {
        if let host = composer.service.dispatchHostName, !host.isEmpty {
            return String(format: L10n.string(
                "mobile.dispatch.picker.searchPrompt.format",
                defaultValue: "Search folders on %@"
            ), host)
        }
        return L10n.string("mobile.dispatch.picker.searchPrompt", defaultValue: "Search folders")
    }

    private var hiddenFoldersMenu: some View {
        Menu {
            Toggle(isOn: $picker.includeHidden) {
                Label(
                    L10n.string("mobile.dispatch.picker.showHidden", defaultValue: "Show Hidden Folders"),
                    systemImage: "eye"
                )
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityIdentifier("MobileDispatchPickerOptions")
    }

    // MARK: - Empty query

    private var suggestedSection: some View {
        Section {
            if composer.recentDirectories.isEmpty {
                Text(L10n.string(
                    "mobile.dispatch.picker.noRecents",
                    defaultValue: "Folders you open workspaces in will show up here."
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                ForEach(composer.recentDirectories) { directory in
                    DispatchDirectoryRow(
                        name: directory.name,
                        detail: composer.displayPath(directory.path),
                        isGit: directory.git,
                        isSelected: composer.directoryPath == directory.path,
                        primaryAction: { handleSelect(directory.path) },
                        browseAction: { browse(directory.path) }
                    )
                }
            }
        } header: {
            pickerSectionHeader(L10n.string("mobile.dispatch.picker.suggested", defaultValue: "Suggested"))
        }
    }

    private var browseRootsSection: some View {
        Section {
            if let home = composer.homePath {
                DispatchDirectoryRow(
                    name: L10n.string("mobile.dispatch.picker.home", defaultValue: "Home"),
                    detail: "~",
                    isGit: false,
                    isSelected: false,
                    systemImage: "house",
                    primaryAction: { browse(home) },
                    browseAction: nil
                )
            }
            DispatchDirectoryRow(
                name: L10n.string("mobile.dispatch.picker.root", defaultValue: "Macintosh HD"),
                detail: "/",
                isGit: false,
                isSelected: false,
                systemImage: "internaldrive",
                primaryAction: { browse("/") },
                browseAction: nil
            )
        } header: {
            pickerSectionHeader(L10n.string("mobile.dispatch.picker.browse", defaultValue: "Browse"))
        } footer: {
            Text(L10n.string(
                "mobile.dispatch.picker.browseFooter",
                defaultValue: "Search covers your home folder, skipping caches and macOS-protected folders like Documents and Downloads; Browse reaches every folder."
            ))
        }
    }

    // MARK: - Search results

    @ViewBuilder
    private var searchResultsSection: some View {
        switch picker.searchState {
        case .idle, .searching:
            Section {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("mobile.dispatch.picker.searching", defaultValue: "Searching…"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        case .failed:
            Section {
                DispatchInlineNotice(
                    icon: "wifi.exclamationmark",
                    text: L10n.string(
                        "mobile.dispatch.picker.searchFailed",
                        defaultValue: "Search didn't reach the Mac."
                    ),
                    actionTitle: L10n.string("mobile.dispatch.retry", defaultValue: "Retry"),
                    action: { picker.retrySearch() }
                )
                .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                .listRowBackground(Color.clear)
            }
        case let .results(entries, indexing, truncated):
            Section {
                if entries.isEmpty, !indexing {
                    Text(L10n.string(
                        "mobile.dispatch.picker.noMatches",
                        defaultValue: "No folders match. Try Browse for folders outside home."
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { directory in
                        DispatchDirectoryRow(
                            name: directory.name,
                            detail: composer.displayPath(directory.path),
                            isGit: directory.git,
                            isSelected: composer.directoryPath == directory.path,
                            primaryAction: { handleSelect(directory.path) },
                            browseAction: { browse(directory.path) }
                        )
                    }
                }
            } footer: {
                if indexing {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(L10n.string(
                            "mobile.dispatch.picker.indexing",
                            defaultValue: "The Mac is still indexing folders. Results are filling in."
                        ))
                    }
                } else if truncated {
                    Text(L10n.string(
                        "mobile.dispatch.picker.truncated",
                        defaultValue: "Showing the closest matches. Keep typing to narrow down."
                    ))
                }
            }
        }
    }

    private func pickerSectionHeader(_ text: String) -> some View {
        Text(text)
            .font(DispatchStyle.fieldLabelFont)
            .tracking(DispatchStyle.fieldLabelTracking)
            .textCase(.uppercase)
    }
}

/// One directory row shared by search results, suggestions, and browse levels.
/// Tapping the row is the primary action; the trailing chevron button descends
/// into the folder when both actions are available.
struct DispatchDirectoryRow: View {
    let name: String
    let detail: String
    let isGit: Bool
    let isSelected: Bool
    var systemImage: String = "folder"
    let primaryAction: () -> Void
    let browseAction: (() -> Void)?

    var body: some View {
        // Sibling buttons, never nested: a Button whose label contains another
        // Button stops receiving row taps inside a List.
        HStack(spacing: 8) {
            Button(action: primaryAction) {
                HStack(spacing: 10) {
                    Image(systemName: systemImage)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(name)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if isGit {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .accessibilityLabel(L10n.string(
                                        "mobile.dispatch.picker.gitBadge",
                                        defaultValue: "Git repository"
                                    ))
                            }
                        }
                        Text(detail)
                            .font(DispatchStyle.monoCaptionFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    Spacer(minLength: 8)
                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let browseAction {
                Button(action: browseAction) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string(
                    "mobile.dispatch.picker.browseInto",
                    defaultValue: "Browse folder"
                ))
            }
        }
    }
}
