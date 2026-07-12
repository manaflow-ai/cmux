import AppKit
import SwiftUI

let browserOmnibarTextFieldIdentifier = NSUserInterfaceItemIdentifier("cmux.browserOmnibarTextField")

struct OmnibarTextFieldRepresentable: NSViewRepresentable {
    let panelId: UUID
    let fontSize: CGFloat
    @Binding var text: String
    @Binding var isFocused: Bool
    let selectAllRequestId: UInt64
    let inlineCompletion: OmnibarInlineCompletion?
    let placeholder: String
    let onTap: () -> Void
    let onSubmit: (OmnibarLiveFieldSnapshot?) -> Void
    let onEscape: () -> Void
    let onFieldLostFocus: () -> Void
    let onMoveSelection: (Int) -> Void
    let onDeleteSelectedSuggestion: () -> Void
    let onAcceptInlineCompletion: () -> Void
    let onDeleteBackwardWithInlineSelection: () -> Void
    let onClearTypedPrefixWithInlineSelection: () -> Void
    let onDeleteWordBackwardWithInlineSelection: () -> Void
    let onSelectionChanged: (NSRange, Bool) -> Void
    let shouldSuppressWebViewFocus: () -> Bool

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OmnibarTextFieldRepresentable
        var isProgrammaticMutation: Bool = false
        var selectionObserver: NSObjectProtocol?
        weak var observedEditor: NSTextView?
        var appliedInlineCompletion: OmnibarInlineCompletion?
        var lastPublishedSelection: NSRange = NSRange(location: NSNotFound, length: 0)
        var lastPublishedHasMarkedText: Bool = false
        /// Guards against infinite focus loops: `true` = focus requested, `false` = blur requested, `nil` = idle.
        var pendingFocusRequest: Bool?
        var pendingSelectAllRequestId: UInt64?
        var appliedSelectAllRequestId: UInt64 = 0

        init(parent: OmnibarTextFieldRepresentable) {
            self.parent = parent
        }
        deinit {
            if let selectionObserver {
                NotificationCenter.default.removeObserver(selectionObserver)
            }
        }
        weak var parentField: OmnibarNativeTextField?
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> OmnibarNativeTextField {
        let field = OmnibarNativeTextField(frame: .zero)
        field.panelId = panelId
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: panelId)
        field.identifier = browserOmnibarTextFieldIdentifier
        field.font = .systemFont(ofSize: fontSize)
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = nil
        field.action = nil
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.stringValue = text
        field.onPointerDown = {
            onTap()
        }
        field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        context.coordinator.parentField = field
        BrowserOmnibarNativeFieldRegistry.shared.register(field, panelId: panelId)
        return field
    }

    func updateNSView(_ nsView: OmnibarNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        if let previousPanelId = nsView.panelId, previousPanelId != panelId {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(nsView, panelId: previousPanelId)
        }
        nsView.panelId = panelId
        BrowserOmnibarNativeFieldRegistry.shared.register(nsView, panelId: panelId)
        nsView.placeholderString = placeholder
        if nsView.font?.pointSize != fontSize {
            nsView.font = .systemFont(ofSize: fontSize)
        }
        context.coordinator.queueSelectAllRequest(selectAllRequestId)

        let activeInlineCompletion = omnibarInlineCompletionIfBufferMatchesTypedPrefix(
            bufferText: text,
            inlineCompletion: inlineCompletion
        )
        let desiredDisplayText = activeInlineCompletion?.displayText ?? text
        if let editor = nsView.currentEditor() as? NSTextView {
            if !editor.hasMarkedText(), editor.string != desiredDisplayText {
                context.coordinator.isProgrammaticMutation = true
                editor.string = desiredDisplayText
                nsView.stringValue = desiredDisplayText
                context.coordinator.isProgrammaticMutation = false
            }
        } else if nsView.stringValue != desiredDisplayText {
            nsView.stringValue = desiredDisplayText
        }

        if let window = nsView.window {
            let firstResponder = window.firstResponder
            let isFirstResponder =
                firstResponder === nsView ||
                nsView.currentEditor() != nil ||
                ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
            if isFocused, !isFirstResponder, context.coordinator.pendingFocusRequest != true {
#if DEBUG
                context.coordinator.logFocusEvent(
                    "updateNSView.requestFocus.begin",
                    detail: "isFocused=1 isFirstResponder=0"
                )
#endif
                // Defer to avoid triggering input method XPC during layout pass,
                // which can crash via re-entrant view hierarchy modification.
                context.coordinator.pendingFocusRequest = true
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let nsView, let window = nsView.window else { return }
#if DEBUG
                    if coordinator?.parent.isFocused != true {
                        coordinator?.logFocusEvent("updateNSView.requestFocus.cancel", detail: "reason=stale_state")
                        return
                    }
#endif
                    guard coordinator?.parent.isFocused == true else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestFocus.tick")
#endif
                    let fr = window.firstResponder
                    let alreadyFocused = fr === nsView ||
                        nsView.currentEditor() != nil ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === nsView
                    if alreadyFocused {
                        coordinator?.applyPendingSelectAllIfPossible(field: nsView)
                        return
                    }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestFocus.apply")
#endif
                    window.makeFirstResponder(nsView)
                    coordinator?.applyPendingSelectAllIfPossible(field: nsView)
                }
            } else if !isFocused, isFirstResponder, context.coordinator.pendingFocusRequest != false {
#if DEBUG
                context.coordinator.logFocusEvent(
                    "updateNSView.requestBlur.begin",
                    detail: "isFocused=0 isFirstResponder=1"
                )
#endif
                context.coordinator.pendingFocusRequest = false
                DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                    coordinator?.pendingFocusRequest = nil
                    guard let nsView, let window = nsView.window else { return }
#if DEBUG
                    if coordinator?.parent.isFocused == true {
                        coordinator?.logFocusEvent("updateNSView.requestBlur.cancel", detail: "reason=stale_state")
                        return
                    }
#endif
                    guard coordinator?.parent.isFocused == false else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestBlur.tick")
#endif
                    let fr = window.firstResponder
                    let stillFirst = fr === nsView ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === nsView
                    guard stillFirst else { return }
#if DEBUG
                    coordinator?.logFocusEvent("updateNSView.requestBlur.apply")
#endif
                    window.makeFirstResponder(nil)
                }
            }
        }
        context.coordinator.applyPendingSelectAllIfPossible(field: nsView)

        if let editor = nsView.currentEditor() as? NSTextView, !editor.hasMarkedText() {
            if let activeInlineCompletion {
                let currentSelection = editor.selectedRange()
                let desiredSelection = omnibarDesiredSelectionRangeForInlineCompletion(
                    currentSelection: currentSelection,
                    inlineCompletion: activeInlineCompletion
                )
                if context.coordinator.appliedInlineCompletion != activeInlineCompletion ||
                    !NSEqualRanges(currentSelection, desiredSelection) {
                    context.coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(desiredSelection)
                    context.coordinator.isProgrammaticMutation = false
                }
            } else if context.coordinator.appliedInlineCompletion != nil {
                let end = text.utf16.count
                let current = editor.selectedRange()
                if current.length != 0 || current.location != end {
                    context.coordinator.isProgrammaticMutation = true
                    editor.setSelectedRange(NSRange(location: end, length: 0))
                    context.coordinator.isProgrammaticMutation = false
                }
            }
        }
        context.coordinator.appliedInlineCompletion = activeInlineCompletion
        context.coordinator.attachSelectionObserverIfNeeded()
        context.coordinator.publishSelectionState()
    }

    static func dismantleNSView(_ nsView: OmnibarNativeTextField, coordinator: Coordinator) {
        if let panelId = nsView.panelId {
            BrowserOmnibarNativeFieldRegistry.shared.unregister(nsView, panelId: panelId)
        }
        nsView.onPointerDown = nil
        nsView.onHandleKeyEvent = nil
        nsView.delegate = nil
        coordinator.detachSelectionObserver()
        coordinator.parentField = nil
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
private func browserOmnibarField(for responder: NSResponder?) -> OmnibarNativeTextField? {
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

