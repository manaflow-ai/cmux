import SwiftUI

#if os(iOS)
import QuickLook
#endif

/// Embeds one artifact preview inside a host surface.
///
/// The modal viewer (`ChatArtifactViewerPager`) is destination-shaped: it owns
/// a navigation title, toolbar actions, paging, and a Done button. Host
/// surfaces that keep an artifact permanently on screen — like a Mac panel
/// mirrored on iOS — need the routed content alone, so this entry point mounts
/// the route view with no navigation chrome. Directory browsing is decided by
/// the loader's scope and stays unreachable for single-file scopes.
public struct ChatArtifactEmbeddedPreview: View {
    private let path: String
    private let scope: ChatArtifactViewerScope
    private let loader: ChatArtifactLoader
    private let refreshToken: String?
    private let connectionHint: ChatArtifactConnectionHint

    /// Creates an embedded, chrome-free artifact preview.
    ///
    /// - Parameters:
    ///   - path: Absolute Mac host path of the previewed file.
    ///   - scope: The user-facing context the preview renders in.
    ///   - loader: The authorized artifact loader for `path`.
    ///   - refreshToken: Opaque descriptor-churn token. When it changes while
    ///     `path` stays stable, the preview re-stats and re-renders the file;
    ///     a `path` change always remounts and reloads.
    public init(
        path: String,
        scope: ChatArtifactViewerScope,
        loader: ChatArtifactLoader,
        refreshToken: String? = nil,
        connectionHint: ChatArtifactConnectionHint = .connected
    ) {
        self.path = path
        self.scope = scope
        self.loader = loader
        self.refreshToken = refreshToken
        self.connectionHint = connectionHint
    }

    public var body: some View {
        EmbeddedArtifactPage(
            path: path,
            scope: scope,
            loader: loader,
            refreshToken: refreshToken,
            connectionHint: connectionHint
        )
        .id(path)
    }
}

/// Path-stable page state for one embedded preview mount.
private struct EmbeddedArtifactPage: View {
    let path: String
    let scope: ChatArtifactViewerScope
    let loader: ChatArtifactLoader
    let refreshToken: String?
    let connectionHint: ChatArtifactConnectionHint

    @State private var model: ChatArtifactViewerPageModel

    init(
        path: String,
        scope: ChatArtifactViewerScope,
        loader: ChatArtifactLoader,
        refreshToken: String?,
        connectionHint: ChatArtifactConnectionHint
    ) {
        self.path = path
        self.scope = scope
        self.loader = loader
        self.refreshToken = refreshToken
        self.connectionHint = connectionHint
        _model = State(initialValue: ChatArtifactViewerPageModel(
            path: path,
            textPreferences: ChatArtifactTextPreferences(defaults: .standard)
        ))
    }

    var body: some View {
        let snapshot = model.snapshot
        ChatArtifactViewerRouteView(
            snapshot: snapshot,
            scope: scope,
            actions: model.actions(
                loader: loader,
                quickLookCanPreview: { fileURL in
                    #if os(iOS)
                    QLPreviewController.canPreview(ChatArtifactQuickLookItem(
                        fileURL: fileURL,
                        title: snapshot.displayName
                    ))
                    #else
                    false
                    #endif
                }
            ),
            connectionHint: connectionHint,
            onDone: {}
        )
        .onChange(of: refreshToken) { _, _ in
            // Descriptor churn with a stable path: the panel may have rewritten
            // its file, so re-stat and re-route without losing the mount.
            model.retry()
        }
    }
}
