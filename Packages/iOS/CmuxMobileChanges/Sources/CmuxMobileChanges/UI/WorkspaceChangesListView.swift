public import SwiftUI

/// Value-driven changed-file list with pinned totals and refresh handling.
public struct WorkspaceChangesListView: View {
    private let branch: String
    private let base: String
    private let totals: ChangesTotals
    private let files: [ChangedFileItem]
    private let state: WorkspaceChangesListState
    private let actions: WorkspaceChangesListActions
    /// Built once per snapshot; collapse toggles only re-flatten it.
    private let tree: ChangedFilesTree
    @Environment(\.colorScheme) private var colorScheme
    /// Directory paths the user folded shut; everything starts expanded.
    @State private var collapsedDirectories: Set<String> = []

    /// Creates a workspace changes list from immutable snapshots.
    /// - Parameters:
    ///   - branch: Current branch display name.
    ///   - base: Comparison base display name.
    ///   - totals: Aggregate change counts.
    ///   - files: Path-sorted changed-file values.
    ///   - state: Current loading, error, empty, or loaded state.
    ///   - actions: Selection and loading closures.
    public init(
        branch: String,
        base: String,
        totals: ChangesTotals,
        files: [ChangedFileItem],
        state: WorkspaceChangesListState,
        actions: WorkspaceChangesListActions
    ) {
        self.branch = branch
        self.base = base
        self.totals = totals
        self.files = files
        self.state = state
        self.actions = actions
        tree = ChangedFilesTree.build(from: files)
    }

    public var body: some View {
        let theme = ChangesTheme(colorScheme: colorScheme)
        List {
            Section {
                switch state {
                case .loading:
                    ForEach(0..<7, id: \.self) { index in
                        WorkspaceChangedFileRow(
                            snapshot: ChangedFileRowSnapshot(
                                index: index,
                                file: ChangedFileItem(
                                    path: "Sources/PlaceholderFile.swift",
                                    kind: .modified,
                                    additions: 12,
                                    deletions: 3,
                                    isBinary: false
                                )
                            ),
                            theme: theme,
                            onSelect: { _ in }
                        )
                        .redacted(reason: .placeholder)
                        .allowsHitTesting(false)
                    }
                case .error:
                    failureView
                case .empty:
                    emptyView
                case .notARepository:
                    notARepositoryView
                case .loaded(let truncated):
                    ForEach(treeRows) { row in
                        switch row {
                        case .directory(let directory):
                            WorkspaceChangedDirectoryRow(row: directory) { path in
                                withAnimation(.snappy(duration: 0.2)) {
                                    if !collapsedDirectories.insert(path).inserted {
                                        collapsedDirectories.remove(path)
                                    }
                                }
                            }
                        case .file(let file):
                            WorkspaceChangedFileRow(
                                snapshot: file.snapshot,
                                theme: theme,
                                indentationDepth: file.depth,
                                showsDirectoryPrefix: false,
                                onSelect: actions.onSelectFile
                            )
                        }
                    }
                    if truncated {
                        Text(String(
                            localized: "changes.files.truncated",
                            defaultValue: "Showing the first 500 changed files. See the rest on your Mac.",
                            bundle: .module
                        ))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .listRowSeparator(.hidden)
                    }
                }
            } header: {
                // A non-repository workspace has no meaningful branch/base or
                // totals, so the summary header is omitted for that state.
                if state != .notARepository {
                    WorkspaceChangesSummaryHeader(
                        branch: branch,
                        base: base,
                        totals: totals,
                        theme: theme
                    )
                }
            }
        }
        .listStyle(.plain)
        .refreshable { await actions.onRefresh() }
    }

    private var treeRows: [ChangedFilesTreeRow] {
        tree.rows(collapsedDirectories: collapsedDirectories)
    }

    private var failureView: some View {
        ContentUnavailableView {
            Label(
                String(localized: "changes.error.title", defaultValue: "Couldn't load changes", bundle: .module),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(String(
                localized: "changes.error.message",
                defaultValue: "Check the connection to your Mac and try again.",
                bundle: .module
            ))
        } actions: {
            Button(String(localized: "changes.retry", defaultValue: "Retry", bundle: .module)) {
                actions.onRetry()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .listRowSeparator(.hidden)
    }

    private var notARepositoryView: some View {
        ContentUnavailableView {
            Label(
                String(
                    localized: "changes.not_repo.title",
                    defaultValue: "Not a Git repository",
                    bundle: .module
                ),
                systemImage: "folder.badge.questionmark"
            )
        } description: {
            Text(String(
                localized: "changes.not_repo.message",
                defaultValue: "This workspace's directory isn't inside a Git repository.",
                bundle: .module
            ))
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .listRowSeparator(.hidden)
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label(
                String(localized: "changes.empty.title", defaultValue: "No changes", bundle: .module),
                systemImage: "doc.text.magnifyingglass"
            )
        } description: {
            Text(String(
                format: String(
                    localized: "changes.empty.message",
                    defaultValue: "This workspace matches %@.",
                    bundle: .module
                ),
                base
            ))
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .listRowSeparator(.hidden)
    }
}
