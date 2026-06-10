import Bonsplit
import SwiftUI
import WebKit
import AppKit
import ObjectiveC


// MARK: - Omnibar Native Text Field
let browserOmnibarTextFieldIdentifier = NSUserInterfaceItemIdentifier("cmux.browserOmnibarTextField")

func browserOmnibarShouldReacquireFocusAfterEndEditing(
    desiredOmnibarFocus: Bool,
    nextResponderIsOtherTextField: Bool
) -> Bool {
    desiredOmnibarFocus && !nextResponderIsOtherTextField
}

func browserOmnibarShouldSelectAllOnFocusReassertion(
    selectionIntent: BrowserAddressBarFocusSelectionIntent
) -> Bool {
    selectionIntent.shouldSelectAll
}

/// Whether a completed single click that just moved first responder into the
/// omnibar should select the field's entire contents (Chrome/Safari/Arc parity),
/// instead of leaving the caret the field editor placed at the click point.
///
/// The first click on an unfocused omnibar showing a URL selects everything so
/// the user can immediately type a replacement. A subsequent click (the field is
/// already first responder, so `gainedFocusOnThisClick` is `false`) keeps the
/// caret placement from https://github.com/manaflow-ai/cmux/issues/5268. A drag
/// or a Shift-click expresses an explicit range, so select-all defers to it; a
/// double-click never reaches this path (the field routes multi-clicks straight
/// to the field editor for word/line selection, and its second click lands after
/// this click's `mouseUp`, so word selection wins).
///
/// - Parameters:
///   - gainedFocusOnThisClick: `true` when the field had no field editor at
///     `mouseDown`, i.e. this click is the one that moved focus into the omnibar.
///   - isShiftClick: `true` when Shift was held, extending an explicit selection.
///   - didDrag: `true` when the pointer moved far enough to build a drag selection.
/// - Returns: `true` only for an undragged, unmodified focus-gaining click.
func browserOmnibarFocusGainingClickShouldSelectAll(
    gainedFocusOnThisClick: Bool,
    isShiftClick: Bool,
    didDrag: Bool
) -> Bool {
    gainedFocusOnThisClick && !isShiftClick && !didDrag
}

final class OmnibarNativeTextField: NSTextField {
    var panelId: UUID?
    var onPointerDown: (() -> Void)?
    var onHandleKeyEvent: ((NSEvent, NSTextView?) -> Bool)?
    var suppressNextFocusReacquireOnEndEditing = false
    /// Anchor index for Shift+click selection extension, reset on non-shift clicks.
    private var shiftClickAnchor: Int?
    private var mouseSelectionState: MouseSelectionState?
    private static let dragSelectionThreshold: CGFloat = 3

    private struct MouseSelectionState {
        let anchor: Int
        let initialWindowLocation: NSPoint
        var didDrag: Bool
        /// `true` when this click moved first responder into the omnibar, gating
        /// the Chrome-style select-all-on-focus behavior applied at `mouseUp`.
        let gainedFocus: Bool
        /// `true` when Shift was held, so an explicit selection extension overrides
        /// the focus-gaining select-all.
        let isShift: Bool
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        lineBreakMode = .byTruncatingTail
        usesSingleLineMode = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    override func mouseDown(with event: NSEvent) {
        let hadEditor = currentEditor() != nil
        onPointerDown?()

        if !hadEditor {
            _ = window?.makeFirstResponder(self)
        }

        guard let editor = currentEditor() as? NSTextView else {
            super.mouseDown(with: event)
            return
        }

        let isShiftClick = event.modifierFlags.contains(.shift)

        // Keep multi-click word and line selection in the field editor, while avoiding
        // NSTextField's mouse tracking loop for ordinary clicks.
        if event.clickCount > 1 {
            mouseSelectionState = nil
            editor.mouseDown(with: event)
            shiftClickAnchor = nil
            return
        }

        let clickIndex = insertionIndex(for: event, in: editor)
        let anchor: Int
        if isShiftClick {
            let selected = editor.selectedRange()
            anchor = shiftClickAnchor ?? selected.location
            shiftClickAnchor = anchor
            setSelection(anchor: anchor, extent: clickIndex, in: editor)
        } else {
            anchor = clickIndex
            shiftClickAnchor = nil
            editor.setSelectedRange(NSRange(location: clickIndex, length: 0))
        }

        mouseSelectionState = MouseSelectionState(
            anchor: anchor,
            initialWindowLocation: event.locationInWindow,
            didDrag: false,
            gainedFocus: !hadEditor,
            isShift: isShiftClick
        )
    }

    override func mouseDragged(with event: NSEvent) {
        guard var state = mouseSelectionState,
              let editor = currentEditor() as? NSTextView else {
            super.mouseDragged(with: event)
            return
        }

        let dx = event.locationInWindow.x - state.initialWindowLocation.x
        let dy = event.locationInWindow.y - state.initialWindowLocation.y
        let distance = (dx * dx + dy * dy).squareRoot()
        if state.didDrag || distance >= Self.dragSelectionThreshold {
            state.didDrag = true
            setSelection(anchor: state.anchor, extent: insertionIndex(for: event, in: editor), in: editor)
            mouseSelectionState = state
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let state = mouseSelectionState else {
            super.mouseUp(with: event)
            return
        }
        mouseSelectionState = nil

        // Chrome/Safari/Arc parity: the click that moves first responder into the
        // omnibar selects the whole URL so the next keystroke replaces it. A click
        // while already focused keeps the caret placed in `mouseDown` (issue #5268),
        // and a drag or Shift-click keeps the explicit range built up during the
        // gesture. Double-clicks never reach here — `mouseDown` routes multi-clicks
        // to the field editor for word/line selection and leaves `mouseSelectionState`
        // nil, and the second click lands after this `mouseUp`, so word selection wins.
        // The keyboard path (Cmd+L) still selects all via the `selectAllRequestId` flow.
        guard browserOmnibarFocusGainingClickShouldSelectAll(
            gainedFocusOnThisClick: state.gainedFocus,
            isShiftClick: state.isShift,
            didDrag: state.didDrag
        ), let editor = currentEditor() as? NSTextView else {
            return
        }
        editor.setSelectedRange(NSRange(location: 0, length: editor.string.utf16.count))
    }

    private func insertionIndex(for event: NSEvent, in editor: NSTextView) -> Int {
        let localPoint = editor.convert(event.locationInWindow, from: nil)
        let index = editor.characterIndexForInsertion(at: localPoint)
        let textLength = (editor.string as NSString).length
        guard index != NSNotFound else { return textLength }
        return min(max(index, 0), textLength)
    }

    private func setSelection(anchor: Int, extent: Int, in editor: NSTextView) {
        if extent >= anchor {
            editor.setSelectedRange(NSRange(location: anchor, length: extent - anchor))
        } else {
            editor.setSelectedRange(NSRange(location: extent, length: anchor - extent))
        }
    }

    override func keyDown(with event: NSEvent) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var route = "super"
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.keyDown",
                startedAt: typingTimingStart,
                event: event,
                extra: "route=\(route)"
            )
        }
#endif
        // Reset shift-click anchor on any keyboard input so that a subsequent
        // Shift+click uses the post-keyboard selection as its anchor, not a
        // stale value from a prior mouse interaction.
        shiftClickAnchor = nil
        mouseSelectionState = nil
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            super.keyDown(with: event)
            return
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
#if DEBUG
            route = "custom"
#endif
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var handled = false
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.performKeyEquivalent",
                startedAt: typingTimingStart,
                event: event,
                extra: "handled=\(handled ? 1 : 0)"
            )
        }
#endif
        shiftClickAnchor = nil
        mouseSelectionState = nil
        if (currentEditor() as? NSTextView)?.hasMarkedText() == true {
            let result = super.performKeyEquivalent(with: event)
#if DEBUG
            handled = result
#endif
            return result
        }
        if onHandleKeyEvent?(event, currentEditor() as? NSTextView) == true {
#if DEBUG
            handled = true
#endif
            return true
        }
        let result = super.performKeyEquivalent(with: event)
#if DEBUG
        handled = result
#endif
        return result
    }
}

@MainActor
func browserOmnibarPanelId(for responder: NSResponder?) -> UUID? {
    browserOmnibarField(for: responder)?.panelId
}

@MainActor
func browserOmnibarField(panelId: UUID?, in window: NSWindow?) -> OmnibarNativeTextField? {
    if let registeredField = BrowserOmnibarNativeFieldRegistry.shared.field(for: panelId, in: window) {
        return registeredField
    }
    guard let panelId, let root = window?.contentView?.superview ?? window?.contentView else {
        return nil
    }

    // Fallback for SwiftUI/AppKit reconnect windows where the live native field
    // has been attached but registration has not yet observed it.
    var stack: [NSView] = [root]
    while let view = stack.popLast() {
        if let field = view as? OmnibarNativeTextField, field.panelId == panelId {
            return field
        }
        stack.append(contentsOf: view.subviews)
    }
    return nil
}

@discardableResult
@MainActor
func browserPrepareOmnibarForProgrammaticBlur(panelId: UUID, responder: NSResponder?) -> Bool {
    guard let field = browserOmnibarField(for: responder),
          field.panelId == panelId else {
        return false
    }
    field.suppressNextFocusReacquireOnEndEditing = true
    return true
}

@MainActor
func browserOmnibarField(for responder: NSResponder?) -> OmnibarNativeTextField? {
    guard let responder else { return nil }

    if let field = responder as? OmnibarNativeTextField {
        return field
    }

    if let editor = responder as? NSTextView, editor.isFieldEditor {
        if let field = BrowserOmnibarNativeFieldRegistry.shared.fieldOwningEditor(editor, in: editor.window) {
            return field
        }

        if let field = cmuxFieldEditorOwnerView(editor) as? OmnibarNativeTextField,
           field.currentEditor() === editor {
            return field
        }

    }

    return nil
}

