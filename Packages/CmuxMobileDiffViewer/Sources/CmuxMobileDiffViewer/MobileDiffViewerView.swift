#if os(iOS)
public import CmuxMobileShellModel
internal import CmuxMobileSupport
public import SwiftUI

/// A read-only diff/file viewer for a workspace's git changes (P1).
///
/// Fetches the workspace's working-tree patch through the injected `load`
/// closure (wired to the paired Mac's `mobile.workspace.diff` RPC), then renders
/// it with the same diff-viewer React bundle the desktop uses, hosted in a
/// `WKWebView` over an app-private custom scheme. It is review-only: no staging,
/// committing, or editing is exposed.
///
/// The load runs in `.task` (no `useEffect`-style imperative effect), and a
/// `reloadToken` lets the user retry without rebuilding the surrounding sheet.
public struct MobileDiffViewerView: View {
    private enum LoadState {
        case loading
        case loaded(MobileWorkspaceDiff)
        case failed(String)
    }

    private let workspaceName: String
    private let prefersDark: Bool
    private let load: @MainActor () async throws -> MobileWorkspaceDiff

    @State private var state: LoadState = .loading
    @State private var reloadToken = 0

    /// Creates a read-only diff viewer.
    /// - Parameters:
    ///   - workspaceName: The workspace's display name (shown as the title).
    ///   - prefersDark: Whether to seed a dark first-paint background.
    ///   - load: Fetches the workspace diff (typically the paired-Mac RPC). Runs
    ///     on the main actor so it can call the `@MainActor` shell store directly.
    public init(
        workspaceName: String,
        prefersDark: Bool,
        load: @escaping @MainActor () async throws -> MobileWorkspaceDiff
    ) {
        self.workspaceName = workspaceName
        self.prefersDark = prefersDark
        self.load = load
    }

    public var body: some View {
        content
            .navigationTitle(workspaceName)
            .navigationBarTitleDisplayMode(.inline)
            .task(id: reloadToken) {
                await runLoad()
            }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            loadingView
        case let .loaded(diff):
            if diff.isEmpty {
                emptyView
            } else {
                loadedView(diff)
            }
        case let .failed(message):
            errorView(message)
        }
    }

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(L10n.string("mobile.diff.loading", defaultValue: "Loading diff…"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        ContentUnavailableView(
            L10n.string("mobile.diff.empty.title", defaultValue: "No changes"),
            systemImage: "checkmark.circle",
            description: Text(L10n.string(
                "mobile.diff.empty.description",
                defaultValue: "This workspace has no uncommitted changes to review."
            ))
        )
    }

    private func loadedView(_ diff: MobileWorkspaceDiff) -> some View {
        VStack(spacing: 0) {
            if diff.truncated {
                truncationBanner
            }
            DiffViewerWebView(diff: diff, title: workspaceName, prefersDark: prefersDark)
                .ignoresSafeArea(edges: .bottom)
        }
    }

    private var truncationBanner: some View {
        Text(L10n.string(
            "mobile.diff.truncated",
            defaultValue: "Diff is large and was truncated for review."
        ))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func errorView(_ message: String) -> some View {
        ContentUnavailableView {
            Label(
                L10n.string("mobile.diff.error.title", defaultValue: "Couldn’t load diff"),
                systemImage: "exclamationmark.triangle"
            )
        } description: {
            Text(message)
        } actions: {
            Button(L10n.string("mobile.diff.retry", defaultValue: "Retry")) {
                state = .loading
                reloadToken += 1
            }
        }
    }

    private func runLoad() async {
        do {
            let diff = try await load()
            guard !Task.isCancelled else { return }
            state = .loaded(diff)
        } catch is CancellationError {
            // The view went away; leave state as-is.
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(
                error.localizedDescription.isEmpty
                    ? L10n.string("mobile.diff.error.generic", defaultValue: "The diff could not be loaded.")
                    : error.localizedDescription
            )
        }
    }
}
#endif
