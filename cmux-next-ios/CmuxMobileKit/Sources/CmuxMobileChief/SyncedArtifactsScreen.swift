#if os(iOS)
import CmuxMobileArtifacts
import CmuxMobileDesign
import SwiftUI

private let theme = CmuxMobileTheme.standard

/// Settings → Artifacts (the Mac's Artifacts page): the account's synced tree, a folder per push,
/// a file's preview, and History (each saved revision, and the file as it was then).
public struct SyncedArtifactsScreen: View {
    let artifacts: SyncedArtifacts?
    let path: String

    public init(artifacts: SyncedArtifacts?, path: String = "") {
        self.artifacts = artifacts
        self.path = path
    }

    public var body: some View {
        Group {
            if let artifacts {
                SyncedFolder(artifacts: artifacts, path: path)
            } else {
                ContentUnavailableView("Sign in to cmux to see your artifacts.", systemImage: "shippingbox")
            }
        }
        .navigationDestination(for: SyncedArtifactRoute.self) { route in
            if let artifacts { route.destination(artifacts) }
        }
    }

    /// The Artifacts page of ``ChiefSources``' signed-in account.
    public static func live(_ sources: ChiefSources = .shared) -> SyncedArtifactsScreen {
        SyncedArtifactsScreen(artifacts: sources.account.map(SyncedArtifacts.init))
    }
}

/// Where a tap in the Artifacts pages goes (one destination for every level).
enum SyncedArtifactRoute: Hashable {
    case folder(String)
    case file(String, ref: String?)
    case history(String, isFile: Bool)

    @MainActor @ViewBuilder func destination(_ artifacts: SyncedArtifacts) -> some View {
        switch self {
        case .folder(let path): SyncedFolder(artifacts: artifacts, path: path)
        case .file(let path, let ref): SyncedFile(artifacts: artifacts, path: path, ref: ref)
        case .history(let path, let isFile): SyncedHistory(artifacts: artifacts, path: path, isFile: isFile)
        }
    }
}

struct SyncedFolder: View {
    let artifacts: SyncedArtifacts
    let path: String
    @State private var page: SyncedArtifactsPage<SyncedArtifacts.Entry>

    init(artifacts: SyncedArtifacts, path: String) {
        self.artifacts = artifacts
        self.path = path
        _page = State(initialValue: SyncedArtifactsPage { try await artifacts.tree(path) })
    }

    var body: some View {
        SyncedPhaseView(phase: page.phase, retry: { await page.load() }) { entries in
            List(entries) { entry in
                NavigationLink(value: entry.isFolder ? SyncedArtifactRoute.folder(entry.path) : .file(entry.path, ref: nil)) {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name).font(theme.type.rowTitle)
                            if let size = entry.size, !entry.isFolder {
                                Text(size.formatted(.byteCount(style: .file))).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                            }
                        }
                    } icon: {
                        Image(systemName: entry.isFolder ? "folder" : "doc")
                    }
                }
                .accessibilityIdentifier("artifacts.synced.entry.\(entry.name)")
            }
            .listStyle(.insetGrouped)
            .overlay {
                if entries.isEmpty {
                    ContentUnavailableView("Nothing has been saved here yet.", systemImage: "shippingbox")
                }
            }
        }
        .navigationTitle(path.isEmpty ? String(localized: "Artifacts") : (path as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: SyncedArtifactRoute.history(path, isFile: false)) {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .accessibilityIdentifier("artifacts.synced.history")
            }
        }
        .refreshable { await page.load() }
        .task { await page.load() }
        .accessibilityIdentifier("artifacts.synced.folder")
    }
}

/// A file's preview at `ref` (the newest when nil), with its History.
struct SyncedFile: View {
    let artifacts: SyncedArtifacts
    let path: String
    let ref: String?
    @State private var showSource = false

    var body: some View {
        ArtifactPreview(artifact: SyncedArtifactSource.artifact(path), source: SyncedArtifactSource(artifacts: artifacts, ref: ref),
                        showSource: $showSource)
            .toolbar {
                if ref == nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        NavigationLink(value: SyncedArtifactRoute.history(path, isFile: true)) {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .accessibilityIdentifier("artifacts.synced.fileHistory")
                    }
                }
            }
            .accessibilityIdentifier("artifacts.synced.file")
    }
}

/// Each saved revision of a path, newest first: its message, who saved it and when. A file's
/// revision opens the file as it was then.
struct SyncedHistory: View {
    let artifacts: SyncedArtifacts
    let path: String
    /// A file's history: each revision opens the file as it was then.
    let isFile: Bool
    @State private var page: SyncedArtifactsPage<SyncedArtifacts.Commit>

    init(artifacts: SyncedArtifacts, path: String, isFile: Bool) {
        self.artifacts = artifacts
        self.path = path
        self.isFile = isFile
        _page = State(initialValue: SyncedArtifactsPage { try await artifacts.history(path) })
    }

    var body: some View {
        SyncedPhaseView(phase: page.phase, retry: { await page.load() }) { commits in
            List(commits) { commit in
                let row = VStack(alignment: .leading, spacing: 3) {
                    Text(commit.message.isEmpty ? commit.shortSHA : commit.message).font(theme.type.rowTitle).lineLimit(2)
                    Text(subtitle(commit)).font(theme.type.meta).foregroundStyle(theme.colors.label2)
                }
                .accessibilityElement(children: .combine)
                if isFile {
                    NavigationLink(value: SyncedArtifactRoute.file(path, ref: commit.sha)) { row }
                        .accessibilityIdentifier("artifacts.synced.commit.\(commit.shortSHA)")
                } else {
                    row.accessibilityIdentifier("artifacts.synced.commit.\(commit.shortSHA)")
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if commits.isEmpty { ContentUnavailableView("No history yet.", systemImage: "clock") }
            }
        }
        .navigationTitle(String(localized: "History"))
        .navigationBarTitleDisplayMode(.inline)
        .task { await page.load() }
        .accessibilityIdentifier("artifacts.synced.historyList")
    }

    private func subtitle(_ commit: SyncedArtifacts.Commit) -> String {
        [commit.time.formatted(date: .abbreviated, time: .shortened), commit.harness, commit.machine, commit.shortSHA]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
            .joined(separator: " · ")
    }
}

/// A page's loading, failure (with Try Again) and loaded states.
struct SyncedPhaseView<Item: Sendable, Content: View>: View {
    let phase: SyncedArtifactsPage<Item>.Phase
    let retry: () async -> Void
    @ViewBuilder let content: ([Item]) -> Content

    var body: some View {
        switch phase {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Couldn't load artifacts", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await retry() } }.buttonStyle(.borderedProminent)
            }
            .accessibilityIdentifier("artifacts.synced.failed")
        case .loaded(let items):
            content(items)
        }
    }
}
#endif
