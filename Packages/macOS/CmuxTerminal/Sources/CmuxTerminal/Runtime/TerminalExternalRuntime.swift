public import CmuxTerminalDomain

/// Compatibility aliases for the persistent-runtime contract now owned by
/// `CmuxTerminalDomain`. Existing clients can keep importing `CmuxTerminal`
/// while the production frontend moves to the Ghostty-free product.
public typealias TerminalExternalPresentation =
    CmuxTerminalDomain.TerminalExternalPresentation
public typealias TerminalExternalPresentationLease =
    CmuxTerminalDomain.TerminalExternalPresentationLease
public typealias TerminalExternalRuntimeLifecycle =
    CmuxTerminalDomain.TerminalExternalRuntimeLifecycle
public typealias TerminalExternalProcessMetadata =
    CmuxTerminalDomain.TerminalExternalProcessMetadata
public typealias TerminalAccessibilityRange =
    CmuxTerminalDomain.TerminalAccessibilityRange
public typealias TerminalAccessibilityCell =
    CmuxTerminalDomain.TerminalAccessibilityCell
public typealias TerminalAccessibilityLine =
    CmuxTerminalDomain.TerminalAccessibilityLine
public typealias TerminalAccessibilityCursor =
    CmuxTerminalDomain.TerminalAccessibilityCursor
public typealias TerminalAccessibilitySelection =
    CmuxTerminalDomain.TerminalAccessibilitySelection
public typealias TerminalAccessibilityLink =
    CmuxTerminalDomain.TerminalAccessibilityLink
public typealias TerminalAccessibilitySnapshot =
    CmuxTerminalDomain.TerminalAccessibilitySnapshot
public typealias TerminalExternalCellMetrics =
    CmuxTerminalDomain.TerminalExternalCellMetrics
public typealias TerminalExternalRuntimeSnapshot =
    CmuxTerminalDomain.TerminalExternalRuntimeSnapshot
public typealias TerminalExternalCellPoint =
    CmuxTerminalDomain.TerminalExternalCellPoint
public typealias TerminalExternalCursorState =
    CmuxTerminalDomain.TerminalExternalCursorState
public typealias TerminalExternalSelection =
    CmuxTerminalDomain.TerminalExternalSelection
public typealias TerminalExternalSearchState =
    CmuxTerminalDomain.TerminalExternalSearchState
public typealias TerminalExternalViewportState =
    CmuxTerminalDomain.TerminalExternalViewportState
public typealias TerminalExternalTextKind =
    CmuxTerminalDomain.TerminalExternalTextKind
public typealias TerminalExternalTextInput =
    CmuxTerminalDomain.TerminalExternalTextInput
public typealias TerminalExternalKeyModifiers =
    CmuxTerminalDomain.TerminalExternalKeyModifiers
public typealias TerminalExternalKeyAction =
    CmuxTerminalDomain.TerminalExternalKeyAction
public typealias TerminalExternalKeyEvent =
    CmuxTerminalDomain.TerminalExternalKeyEvent
public typealias TerminalExternalInput =
    CmuxTerminalDomain.TerminalExternalInput
public typealias TerminalExternalViewport =
    CmuxTerminalDomain.TerminalExternalViewport
public typealias TerminalExternalMouseAction =
    CmuxTerminalDomain.TerminalExternalMouseAction
public typealias TerminalExternalMouseButton =
    CmuxTerminalDomain.TerminalExternalMouseButton
public typealias TerminalExternalMouseEvent =
    CmuxTerminalDomain.TerminalExternalMouseEvent
public typealias TerminalExternalHyperlinkHit =
    CmuxTerminalDomain.TerminalExternalHyperlinkHit
public typealias TerminalExternalPreedit =
    CmuxTerminalDomain.TerminalExternalPreedit
public typealias TerminalExternalRuntimeMutation =
    CmuxTerminalDomain.TerminalExternalRuntimeMutation
public typealias TerminalExternalSelectionOperation =
    CmuxTerminalDomain.TerminalExternalSelectionOperation
public typealias TerminalExternalCopyModeOperation =
    CmuxTerminalDomain.TerminalExternalCopyModeOperation
public typealias TerminalExternalCopyModeAdjustment =
    CmuxTerminalDomain.TerminalExternalCopyModeAdjustment
public typealias TerminalExternalSearchOperation =
    CmuxTerminalDomain.TerminalExternalSearchOperation
public typealias TerminalExternalScrollOperation =
    CmuxTerminalDomain.TerminalExternalScrollOperation
public typealias TerminalExternalIngressRejection =
    CmuxTerminalDomain.TerminalExternalIngressRejection
public typealias TerminalExternalIngressResult =
    CmuxTerminalDomain.TerminalExternalIngressResult
public typealias TerminalExternalScreenTextRequest =
    CmuxTerminalDomain.TerminalExternalScreenTextRequest
public typealias TerminalExternalRuntime =
    CmuxTerminalDomain.TerminalExternalRuntime
