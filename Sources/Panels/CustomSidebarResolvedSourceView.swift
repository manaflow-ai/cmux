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
/// The content closure is handed an already-decided mount, never a file to inspect. Deciding means
/// probing the sidebars directory and, for a `.url` file, reading it — and this view's content
/// re-evaluates about once a second, so doing that work here would be a per-second main-thread
/// stall. The observer does it off the main thread and publishes the result.
///
/// The observer is keyed to the name it was built with, so a call site that can change names must
/// apply `.id(name)` to rebuild it.
struct CustomSidebarResolvedSourceView<Content: View>: View {
    @State private var observer: CustomSidebarWebReloadObserver
    private let content: (CustomSidebarMountDecision, CustomSidebarWebReloadToken) -> Content

    /// Creates the scope for one sidebar name.
    ///
    /// - Parameters:
    ///   - sidebarName: The sidebar to resolve and answer reload requests for.
    ///   - fallbackFileURL: What to mount while the name resolves to nothing. A pane passes the file
    ///     it was opened on, so a sidebar being edited in place — briefly absent from disk — keeps
    ///     rendering instead of blanking. The rail passes `nil`, since it is switched away entirely
    ///     when its sidebar stops resolving.
    ///   - content: Renders the decided mount. Receives `.unavailable` when the name resolves to
    ///     nothing usable, so a rejected web source cannot fall through to the interpreter.
    init(
        sidebarName: String,
        fallbackFileURL: URL? = nil,
        @ViewBuilder content: @escaping (CustomSidebarMountDecision, CustomSidebarWebReloadToken) -> Content
    ) {
        _observer = State(
            initialValue: CustomSidebarWebReloadObserver(
                sidebarName: sidebarName,
                fallbackFileURL: fallbackFileURL
            ) { name in
                CmuxExtensionSidebarSelection.customSidebarFileURL(forName: name)
            }
        )
        self.content = content
    }

    var body: some View {
        Group {
            if let decision = observer.mountDecision {
                content(decision, observer.reloadToken)
            } else {
                // Before the first resolution lands there is no honest answer yet. Rendering nothing
                // for that moment beats the alternatives: an error state would flash on every
                // healthy mount, and the interpreter is the lane a rejected web source must never
                // reach.
                Color.clear
            }
        }
        .onAppear { observer.start() }
        .onDisappear { observer.stop() }
    }
}
