import CmuxBrowser
import Foundation

/// Shared surface of both Chromium-engine adapters (child-process streamed
/// and in-process CEF), so pane and automation call sites stay engine-agnostic.
@MainActor
protocol ChromiumEngineAdapting: AnyObject {
    /// Receives lifecycle and page-metadata snapshots.
    var onSnapshot: ((ChromiumSessionSnapshot) -> Void)? { get set }
    /// Fires when web content takes first-responder focus.
    var onContentFocused: (() -> Void)? { get set }
    /// Applies or clears prefers-color-scheme emulation.
    func setEmulatedColorScheme(_ scheme: String?)
    /// Removes every registered document-start script.
    func clearDocumentScripts()
    /// Registers a document-start script; returns its 1-based ordinal.
    func registerDocumentScript(_ source: String, isStyle: Bool) async throws -> Int
    /// Removes one document-start script after a failed immediate evaluation.
    func removeDocumentScript(_ source: String, isStyle: Bool)
    /// Returns stored document scripts for replay into a replacement engine.
    func documentScriptDefinitions() -> [(source: String, isStyle: Bool)]
    /// Cancels the active page load.
    func stopLoadingPage()
    /// Tells the renderer whether this pane currently needs a visible viewport.
    /// Hidden streamed panes suspend screencast production and frame decoding;
    /// CEF panes order their native child window out through the same seam.
    func setPaneVisible(_ visible: Bool)
}

extension ChromiumBrowserPaneEngineAdapter: ChromiumEngineAdapting {
    func stopLoadingPage() {
        let session = self.session
        Task { try? await session.stopLoading() }
    }

    func setPaneVisible(_ visible: Bool) {
        hostView.setPaneVisible(visible)
    }
}

extension CEFBrowserPaneEngineAdapter: ChromiumEngineAdapting {
    func setPaneVisible(_ visible: Bool) {
        hostView.isPaneVisible = visible
    }
}
