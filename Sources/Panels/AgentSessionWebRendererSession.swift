import Foundation

@MainActor
final class AgentSessionWebRendererSession {
    private let ownedCoordinator = AgentSessionWebRendererCoordinator()
    var onHasActiveProviderChanged: ((Bool) -> Void)? {
        didSet {
            ownedCoordinator.onHasActiveProviderChanged = onHasActiveProviderChanged
        }
    }
    var onProviderIDChanged: ((AgentSessionProviderID) -> Void)? {
        didSet {
            ownedCoordinator.onProviderIDChanged = onProviderIDChanged
        }
    }
    /// Web composer text changed locally (host typing); see
    /// ``AgentSessionWebRendererCoordinator/onComposerTextChanged``.
    var onComposerTextChanged: ((String) -> Void)? {
        didSet {
            ownedCoordinator.onComposerTextChanged = onComposerTextChanged
        }
    }

    /// The live web view, if the renderer has created one. Multiplayer share
    /// snapshots it for pixel streaming; never retained beyond the call.
    var webView: AgentSessionWebView? {
        ownedCoordinator.webView
    }

    /// Pushes authoritative composer text into the web composer.
    func setComposerText(_ text: String, caretStart: Int? = nil, caretEnd: Int? = nil) {
        ownedCoordinator.setComposerText(text, caretStart: caretStart, caretEnd: caretEnd)
    }

    func coordinator(
        panelId: UUID,
        workspaceId: UUID,
        rendererKind: AgentSessionRendererKind,
        initialProviderID: AgentSessionProviderID,
        workingDirectory: String?,
        theme: AgentSessionWebTheme,
        isFocused: Bool
    ) -> AgentSessionWebRendererCoordinator {
        ownedCoordinator.bind(
            panelId: panelId,
            workspaceId: workspaceId,
            rendererKind: rendererKind,
            initialProviderID: initialProviderID,
            workingDirectory: workingDirectory,
            theme: theme,
            isFocused: isFocused
        )
        return ownedCoordinator
    }

    func focus() {
        ownedCoordinator.focus()
    }

    func unfocus() {
        ownedCoordinator.unfocus()
    }

    func close() {
        ownedCoordinator.close()
    }
}
