import CmuxTerminal

/// Cache and renderer changes produced by one ordered backend mutation.
struct TerminalBackendMutationOutcome: Equatable, Sendable {
    var lifecycle: TerminalExternalRuntimeLifecycle = .live
    var visibleText: String?
    var processMetadata: TerminalExternalProcessMetadata?
    var needsCloseConfirmation: Bool?
    var copyModeActive: Bool?
    var mouseTracking: Bool?
    var copyCursor: TerminalExternalCellPoint?
    var cursor: TerminalExternalCursorState?
    var terminalUXWasRead = false
    var selection: TerminalExternalSelection?
    var selectionWasRead = false
    var search: TerminalExternalSearchState?
    var viewportState: TerminalExternalViewportState?
    var clipboardText: String?
    var actionHandled: Bool?
    var rendererAttachment: TerminalBackendRendererAttachment?
    var rendererActivation: TerminalBackendRendererActivation?
    var binding: TerminalBackendTerminalBinding?
}
