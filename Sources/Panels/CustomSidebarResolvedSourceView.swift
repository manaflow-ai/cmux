import CmuxFoundation
import CmuxSidebar
import SwiftUI

/// Resolves a custom sidebar name to the file that currently wins, and re-resolves it on every
/// `cmux sidebar reload`.
///
/// Both surfaces that host a custom sidebar — the workspace rail and a Dock pane — used to capture
/// their file once, at mount. That is wrong in two ways the user experiences as the same bug. A web
/// sidebar has no render model listening for the reload notification, so `cmux sidebar reload board`
/// did nothing at all to a hosted page. And the name-to-file mapping can change under a live
/// surface: adding `board.swift` beside `board.html` promotes the interpreted file, deleting it
/// demotes back to the page. A captured file keeps rendering the loser for as long as the surface
/// lives.
///
/// Owning the observer here rather than in each surface keeps one answer to "which file is this
/// sidebar" for the rail and the pane, which is the same reason the extension order lives in
/// ``CustomSidebarSource``.
///
/// The observer is keyed to the name it was built with, so a call site that can change names must
/// apply `.id(name)` to rebuild it.
struct CustomSidebarResolvedSourceView<Content: View>: View {
    @State private var observer: CustomSidebarWebReloadObserver
    private let content: (URL?, CustomSidebarWebReloadToken) -> Content

    /// Creates the scope for one sidebar name.
    ///
    /// - Parameters:
    ///   - sidebarName: The sidebar to resolve and answer reload requests for.
    ///   - content: Renders the currently resolved file. Receives `nil` once every file backing the
    ///     name is gone, so a caller can decide between an error state and its last known file
    ///     rather than having that choice made for it.
    init(
        sidebarName: String,
        @ViewBuilder content: @escaping (URL?, CustomSidebarWebReloadToken) -> Content
    ) {
        _observer = State(initialValue: CustomSidebarWebReloadObserver(sidebarName: sidebarName) { name in
            CmuxExtensionSidebarSelection.customSidebarFileURL(forName: name)
        })
        self.content = content
    }

    var body: some View {
        content(observer.resolvedFileURL, observer.reloadToken)
            .onAppear { observer.start() }
            .onDisappear { observer.stop() }
    }
}
