#if os(iOS) && DEBUG
import CmuxMobileChanges
import CmuxMobileSupport
import SwiftUI
import UIKit

/// Deterministic changes sheet fixture selected by `CMUX_UITEST_CHANGES_PREVIEW`.
public struct ChangesPreviewView: View {
    private let fixture = ChangesPreviewFixture()
    private let mode: String
    private let fontPreference: DiffFontPreference
    @State private var cachedDocuments: [String: FileDiffDocument] = [:]
    @State private var fontSize: Double
    @State private var stateVariant: ChangesPreviewStateVariant = .loading
    @State private var navigationPath: [WorkspaceChangesNavigationRoute] = []

    /// Creates the preview from the current UI-test environment.
    public init() {
        let resolvedMode = UITestConfig.changesPreviewMode ?? "1"
        mode = resolvedMode
        let preference = DiffFontPreference(defaults: .standard)
        fontPreference = preference
        _fontSize = State(initialValue: preference.pointSize)
        _navigationPath = State(initialValue: resolvedMode == "diff" ? [.diff(2)] : [])
    }

    public var body: some View {
        VStack(spacing: 0) {
            if mode == "states" {
                Picker(
                    String(localized: "workspace.changes.preview.state", defaultValue: "State", bundle: .module),
                    selection: $stateVariant
                ) {
                    Text(String(
                        localized: "workspace.changes.preview.loading",
                        defaultValue: "Loading",
                        bundle: .module
                    ))
                    .tag(ChangesPreviewStateVariant.loading)
                    Text(String(
                        localized: "workspace.changes.preview.error",
                        defaultValue: "Error",
                        bundle: .module
                    ))
                    .tag(ChangesPreviewStateVariant.error)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }
            WorkspaceChangesNavigationView(
                branch: fixture.branch,
                base: fixture.base,
                totals: displayedTotals,
                files: displayedFiles,
                listState: displayedState,
                cachedDocuments: cachedDocuments,
                fontSize: fontSize,
                listActions: listActions,
                pagerActions: pagerActions,
                path: $navigationPath,
                onClose: {}
            )
        }
    }

    private var displayedFiles: [ChangedFileItem] {
        mode == "empty" ? [] : fixture.files
    }

    private var displayedTotals: ChangesTotals {
        mode == "empty" ? ChangesTotals(filesChanged: 0, additions: 0, deletions: 0) : fixture.totals
    }

    private var displayedState: WorkspaceChangesListState {
        switch mode {
        case "empty": .empty
        case "states": stateVariant == .loading ? .loading : .error
        default: .loaded
        }
    }

    private var listActions: WorkspaceChangesListActions {
        WorkspaceChangesListActions(
            onSelectFile: { _ in },
            onRefresh: {
                // An intentional bounded fixture delay keeps refresh/loading visible for pixel review.
                try? await ContinuousClock().sleep(for: .milliseconds(150))
                cachedDocuments = [:]
            },
            onRetry: { stateVariant = .loading }
        )
    }

    private var pagerActions: WorkspaceFileDiffPagerActions {
        WorkspaceFileDiffPagerActions(
            onLoad: { path, forceRefresh in
                if !forceRefresh, let cached = cachedDocuments[path] { return cached }
                // An intentional bounded fixture delay makes the real skeleton observable.
                try await ContinuousClock().sleep(for: .milliseconds(150))
                guard let document = fixture.documents[path] else {
                    throw ChangesPreviewError.missingDocument
                }
                cachedDocuments[path] = document
                return document
            },
            onPersistFontSize: { pointSize in
                fontSize = pointSize
                fontPreference.pointSize = pointSize
            },
            onCopy: { UIPasteboard.general.string = $0 },
            inlinePreview: nil
        )
    }
}
#endif
