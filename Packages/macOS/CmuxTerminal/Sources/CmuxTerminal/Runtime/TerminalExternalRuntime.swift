public import CmuxTerminalDomain

/// Compatibility aliases for the persistent-runtime contract now owned by
/// `CmuxTerminalDomain`. Existing clients can keep importing `CmuxTerminal`
/// while the production frontend moves to the Ghostty-free product.
/// A durable externally-rendered terminal presentation.
public typealias TerminalExternalPresentation =
    CmuxTerminalDomain.TerminalExternalPresentation
/// A lease that owns one external presentation attachment.
public typealias TerminalExternalPresentationLease =
    CmuxTerminalDomain.TerminalExternalPresentationLease
/// Lifecycle state for an external terminal runtime.
public typealias TerminalExternalRuntimeLifecycle =
    CmuxTerminalDomain.TerminalExternalRuntimeLifecycle
/// Process metadata published by an external runtime.
public typealias TerminalExternalProcessMetadata =
    CmuxTerminalDomain.TerminalExternalProcessMetadata
/// A terminal accessibility text range.
public typealias TerminalAccessibilityRange =
    CmuxTerminalDomain.TerminalAccessibilityRange
/// A terminal accessibility cell.
public typealias TerminalAccessibilityCell =
    CmuxTerminalDomain.TerminalAccessibilityCell
/// A terminal accessibility line.
public typealias TerminalAccessibilityLine =
    CmuxTerminalDomain.TerminalAccessibilityLine
/// A terminal accessibility cursor.
public typealias TerminalAccessibilityCursor =
    CmuxTerminalDomain.TerminalAccessibilityCursor
/// A terminal accessibility selection.
public typealias TerminalAccessibilitySelection =
    CmuxTerminalDomain.TerminalAccessibilitySelection
/// A terminal accessibility link.
public typealias TerminalAccessibilityLink =
    CmuxTerminalDomain.TerminalAccessibilityLink
/// A complete terminal accessibility snapshot.
public typealias TerminalAccessibilitySnapshot =
    CmuxTerminalDomain.TerminalAccessibilitySnapshot
/// Cell metrics published by an external runtime.
public typealias TerminalExternalCellMetrics =
    CmuxTerminalDomain.TerminalExternalCellMetrics
/// A complete external runtime snapshot.
public typealias TerminalExternalRuntimeSnapshot =
    CmuxTerminalDomain.TerminalExternalRuntimeSnapshot
/// A cell coordinate in an external runtime.
public typealias TerminalExternalCellPoint =
    CmuxTerminalDomain.TerminalExternalCellPoint
/// Cursor state published by an external runtime.
public typealias TerminalExternalCursorState =
    CmuxTerminalDomain.TerminalExternalCursorState
/// Selection state published by an external runtime.
public typealias TerminalExternalSelection =
    CmuxTerminalDomain.TerminalExternalSelection
/// Search state published by an external runtime.
public typealias TerminalExternalSearchState =
    CmuxTerminalDomain.TerminalExternalSearchState
/// Viewport state published by an external runtime.
public typealias TerminalExternalViewportState =
    CmuxTerminalDomain.TerminalExternalViewportState
/// The semantic kind of external terminal text.
public typealias TerminalExternalTextKind =
    CmuxTerminalDomain.TerminalExternalTextKind
/// Text input sent to an external runtime.
public typealias TerminalExternalTextInput =
    CmuxTerminalDomain.TerminalExternalTextInput
/// Modifier keys sent with an external key event.
public typealias TerminalExternalKeyModifiers =
    CmuxTerminalDomain.TerminalExternalKeyModifiers
/// The action phase of an external key event.
public typealias TerminalExternalKeyAction =
    CmuxTerminalDomain.TerminalExternalKeyAction
/// A key event sent to an external runtime.
public typealias TerminalExternalKeyEvent =
    CmuxTerminalDomain.TerminalExternalKeyEvent
/// An input operation sent to an external runtime.
public typealias TerminalExternalInput =
    CmuxTerminalDomain.TerminalExternalInput
/// A viewport update sent to an external runtime.
public typealias TerminalExternalViewport =
    CmuxTerminalDomain.TerminalExternalViewport
/// The action phase of an external mouse event.
public typealias TerminalExternalMouseAction =
    CmuxTerminalDomain.TerminalExternalMouseAction
/// A mouse button in an external runtime event.
public typealias TerminalExternalMouseButton =
    CmuxTerminalDomain.TerminalExternalMouseButton
/// A mouse event sent to an external runtime.
public typealias TerminalExternalMouseEvent =
    CmuxTerminalDomain.TerminalExternalMouseEvent
/// The hyperlink found at an external runtime position.
public typealias TerminalExternalHyperlinkHit =
    CmuxTerminalDomain.TerminalExternalHyperlinkHit
/// Input-method preedit text sent to an external runtime.
public typealias TerminalExternalPreedit =
    CmuxTerminalDomain.TerminalExternalPreedit
/// A state mutation requested from an external runtime.
public typealias TerminalExternalRuntimeMutation =
    CmuxTerminalDomain.TerminalExternalRuntimeMutation
/// A selection mutation requested from an external runtime.
public typealias TerminalExternalSelectionOperation =
    CmuxTerminalDomain.TerminalExternalSelectionOperation
/// A copy-mode mutation requested from an external runtime.
public typealias TerminalExternalCopyModeOperation =
    CmuxTerminalDomain.TerminalExternalCopyModeOperation
/// A copy-mode adjustment requested from an external runtime.
public typealias TerminalExternalCopyModeAdjustment =
    CmuxTerminalDomain.TerminalExternalCopyModeAdjustment
/// A search mutation requested from an external runtime.
public typealias TerminalExternalSearchOperation =
    CmuxTerminalDomain.TerminalExternalSearchOperation
/// A scroll mutation requested from an external runtime.
public typealias TerminalExternalScrollOperation =
    CmuxTerminalDomain.TerminalExternalScrollOperation
/// A reason that external input was rejected.
public typealias TerminalExternalIngressRejection =
    CmuxTerminalDomain.TerminalExternalIngressRejection
/// The result of sending input to an external runtime.
public typealias TerminalExternalIngressResult =
    CmuxTerminalDomain.TerminalExternalIngressResult
/// A request for text from an external runtime screen.
public typealias TerminalExternalScreenTextRequest =
    CmuxTerminalDomain.TerminalExternalScreenTextRequest
/// The persistent external terminal runtime contract.
public typealias TerminalExternalRuntime =
    CmuxTerminalDomain.TerminalExternalRuntime
