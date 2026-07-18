import AppKit
import SwiftUI

@MainActor
extension OmnibarTextFieldRepresentable.Coordinator {

#if DEBUG
    func logFocusEvent(_ event: String, detail: String = "") {
        let window = parentField?.window
        let responder = window?.firstResponder
        let responderType = responder.map { String(describing: type(of: $0)) } ?? "nil"
        let responderIsField: Int = {
            guard let field = parentField else { return 0 }
            if responder === field { return 1 }
            if let editor = responder as? NSTextView,
               (editor.delegate as? NSTextField) === field {
                return 1
            }
            return 0
        }()
        let pendingValue: String = {
            guard let pendingFocusRequest else { return "nil" }
            return pendingFocusRequest ? "focus" : "blur"
        }()
        var line =
            "browser.focus.field event=\(event) focused=\(parent.isFocused ? 1 : 0) " +
            "pending=\(pendingValue) suppressWeb=\(parent.shouldSuppressWebViewFocus() ? 1 : 0) " +
            "win=\(window?.windowNumber ?? -1) fr=\(responderType) frIsField=\(responderIsField)"
        if !detail.isEmpty {
            line += " \(detail)"
        }
        cmuxDebugLog(line)
    }
#endif

    func nextResponderIsOtherTextField(window: NSWindow?) -> Bool {
        guard let window, let field = parentField else { return false }
        let responder = window.firstResponder

        if let editor = responder as? NSTextView,
           let delegateField = editor.delegate as? NSTextField {
            return delegateField !== field
        }

        if let textField = responder as? NSTextField {
            return textField !== field
        }

        return false
    }

    func isPointerDownEvent(_ event: NSEvent) -> Bool {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        default:
            return false
        }
    }

    func topHitViewForCurrentPointerEvent(window: NSWindow) -> NSView? {
        guard let event = NSApp.currentEvent, isPointerDownEvent(event) else {
            return nil
        }
        if event.windowNumber != 0, event.windowNumber != window.windowNumber {
            return nil
        }
        if let eventWindow = event.window, eventWindow !== window {
            return nil
        }

        if let contentView = window.contentView,
           let themeFrame = contentView.superview {
            let pointInTheme = themeFrame.convert(event.locationInWindow, from: nil)
            if let hitInTheme = themeFrame.hitTest(pointInTheme) {
                return hitInTheme
            }
        }

        guard let contentView = window.contentView else {
            return nil
        }
        let pointInContent = contentView.convert(event.locationInWindow, from: nil)
        return contentView.hitTest(pointInContent)
    }

    func pointerDownBlurIntent(window: NSWindow?) -> Bool {
        guard let window, let field = parentField else { return false }
        guard let hitView = topHitViewForCurrentPointerEvent(window: window) else {
            return false
        }

        if hitView === field || hitView.isDescendant(of: field) {
            return false
        }
        if let interactionView = hitView as? BrowserOmnibarInteractionView,
           interactionView.panelId == field.panelId {
            return false
        }
        if let textView = hitView as? NSTextView,
           let delegateField = textView.delegate as? NSTextField,
           delegateField === field {
            return false
        }
        return true
    }

    func shouldReacquireFocusAfterEndEditing(window: NSWindow?) -> Bool {
        if parentField?.suppressNextFocusReacquireOnEndEditing == true {
            return false
        }
        if pointerDownBlurIntent(window: window) {
            return false
        }
        return browserOmnibarShouldReacquireFocusAfterEndEditing(
            desiredOmnibarFocus: parent.isFocused,
            nextResponderIsOtherTextField: nextResponderIsOtherTextField(window: window)
        )
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
#if DEBUG
        logFocusEvent("controlTextDidBeginEditing")
#endif
        if !parent.isFocused {
            DispatchQueue.main.async {
#if DEBUG
                self.logFocusEvent("controlTextDidBeginEditing.asyncSetFocused", detail: "old=0 new=1")
#endif
                self.parent.isFocused = true
            }
        }
        attachSelectionObserverIfNeeded()
        if let field = obj.object as? OmnibarNativeTextField {
            field.suppressNextFocusReacquireOnEndEditing = false
            applyPendingSelectAllIfPossible(field: field)
        }
        publishSelectionState()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let shouldReacquire = shouldReacquireFocusAfterEndEditing(window: parentField?.window)
#if DEBUG
        let nextOther = nextResponderIsOtherTextField(window: parentField?.window)
        let pointerBlur = pointerDownBlurIntent(window: parentField?.window)
        logFocusEvent(
            "controlTextDidEndEditing",
            detail: "nextOther=\(nextOther ? 1 : 0) pointerBlur=\(pointerBlur ? 1 : 0) shouldReacquire=\(shouldReacquire ? 1 : 0)"
        )
#endif
        if parent.isFocused {
            if shouldReacquire {
#if DEBUG
                logFocusEvent("controlTextDidEndEditing.reacquire.begin")
#endif
                guard pendingFocusRequest != true else { return }
                pendingFocusRequest = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingFocusRequest = nil
#if DEBUG
                    self.logFocusEvent("controlTextDidEndEditing.reacquire.tick")
#endif
                    guard self.parent.isFocused else { return }
                    guard let field = self.parentField, let window = field.window else { return }
                    guard self.shouldReacquireFocusAfterEndEditing(window: window) else {
#if DEBUG
                        self.logFocusEvent("controlTextDidEndEditing.reacquire.cancel")
#endif
                        self.parent.onFieldLostFocus()
                        return
                    }
                    // Check both the field itself AND its field editor (which becomes
                    // the actual first responder when the text field is being edited).
                    let fr = window.firstResponder
                    let isAlreadyFocused = fr === field ||
                        field.currentEditor() != nil ||
                        ((fr as? NSTextView)?.delegate as? NSTextField) === field
                    if !isAlreadyFocused {
#if DEBUG
                        self.logFocusEvent("controlTextDidEndEditing.reacquire.apply")
#endif
                        window.makeFirstResponder(field)
                    } else {
#if DEBUG
                        self.logFocusEvent("controlTextDidEndEditing.reacquire.skip", detail: "reason=already_focused")
#endif
                    }
                }
                return
            }
#if DEBUG
            logFocusEvent("controlTextDidEndEditing.blur")
#endif
            parent.onFieldLostFocus()
        }
        parentField?.suppressNextFocusReacquireOnEndEditing = false
        detachSelectionObserver()
    }

    func controlTextDidChange(_ obj: Notification) {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.controlTextDidChange",
                startedAt: typingTimingStart,
                event: NSApp.currentEvent,
                extra: "programmatic=\(isProgrammaticMutation ? 1 : 0)"
            )
        }
#endif
        guard !isProgrammaticMutation else { return }
        guard let field = obj.object as? NSTextField else { return }
        let editor = field.currentEditor() as? NSTextView
        publishSelectionState()
        parent.text = omnibarPublishedBufferTextForFieldChange(
            fieldValue: field.stringValue,
            inlineCompletion: parent.inlineCompletion,
            selectionRange: editor?.selectedRange(),
            hasMarkedText: editor?.hasMarkedText() ?? false
        )
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
#if DEBUG
        let typingTimingStart = CmuxTypingTiming.start()
        var handled = false
        defer {
            CmuxTypingTiming.logDuration(
                path: "browser.omnibar.doCommandBy",
                startedAt: typingTimingStart,
                event: NSApp.currentEvent,
                extra: "handled=\(handled ? 1 : 0) selector=\(NSStringFromSelector(commandSelector))"
            )
        }
#endif
        guard !textView.hasMarkedText() else { return false }
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            parent.onMoveSelection(+1)
#if DEBUG
            handled = true
#endif
            return true
        case #selector(NSResponder.moveUp(_:)):
            parent.onMoveSelection(-1)
#if DEBUG
            handled = true
#endif
            return true
        case #selector(NSResponder.insertNewline(_:)):
            let currentFlags = NSApp.currentEvent?.modifierFlags ?? []
            guard browserOmnibarShouldSubmitOnReturn(flags: currentFlags) else { return false }
            parent.onSubmit(liveFieldSnapshot(preferredEditor: textView))
#if DEBUG
            handled = true
#endif
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            parent.onEscape()
#if DEBUG
            handled = true
#endif
            return true
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
            if parent.inlineCompletion != nil {
                parent.onAcceptInlineCompletion()
#if DEBUG
                handled = true
#endif
                return true
            }
            return false
        case #selector(NSResponder.insertTab(_:)):
            if parent.inlineCompletion != nil {
                parent.onAcceptInlineCompletion()
#if DEBUG
                handled = true
#endif
                return true
            }
            return false
        case #selector(NSResponder.deleteBackward(_:)):
            if suffixSelectionMatchesInline(textView, inline: parent.inlineCompletion) {
                parent.onDeleteBackwardWithInlineSelection()
#if DEBUG
                handled = true
#endif
                return true
            }
            return false
        case #selector(NSResponder.deleteToBeginningOfLine(_:)),
             #selector(NSResponder.deleteToBeginningOfParagraph(_:)):
            if inlineCompletionSelectionIsActive(textView, inline: parent.inlineCompletion) {
                parent.onClearTypedPrefixWithInlineSelection()
#if DEBUG
                handled = true
#endif
                return true
            }
            return false
        case #selector(NSResponder.deleteWordBackward(_:)):
            if inlineCompletionSelectionIsActive(textView, inline: parent.inlineCompletion) {
                parent.onDeleteWordBackwardWithInlineSelection()
#if DEBUG
                handled = true
#endif
                return true
            }
            return false
        default:
            return false
        }
    }

    func attachSelectionObserverIfNeeded() {
        guard selectionObserver == nil else { return }
        guard let field = parentField else { return }
        guard let editor = field.currentEditor() as? NSTextView else { return }
        observedEditor = editor
        selectionObserver = NotificationCenter.default.addObserver(
            forName: NSTextView.didChangeSelectionNotification,
            object: editor,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishSelectionState()
            }
        }
    }

    func detachSelectionObserver() {
        if let selectionObserver {
            NotificationCenter.default.removeObserver(selectionObserver)
            self.selectionObserver = nil
        }
        observedEditor = nil
    }

}

