public import AppKit
public import SwiftUI
#if DEBUG
internal import CMUXDebugLog
#endif

// Keep navigation on the AppKit field editor so scope switches preserve arrow-key handlers.
/// `NSViewRepresentable` exposing the single-line command-palette search field
/// to SwiftUI.
///
/// Binds text and focus, and surfaces submit/escape/selection-move callbacks.
/// Keyboard-shortcut routing decisions (which navigation delta a key or field
/// editor command maps to, and whether Return should submit) are injected as
/// closures, so the field never reaches back into the host's shortcut store.
public struct CommandPaletteSearchFieldRepresentable: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool
    let onSubmit: () -> Void
    let onEscape: () -> Void
    let onMoveSelection: (Int) -> Void
    let onUnhandledNavigationKey: (NSEvent) -> Bool
    let fieldEditorNavigationDelta: (Selector, NSEvent?) -> Int?
    let keyEventNavigationDelta: (NSEvent) -> Int?
    let shouldSubmitWithReturn: (NSEvent) -> Bool

    /// Creates the search-field representable.
    /// - Parameters:
    ///   - placeholder: Placeholder text shown while the field is empty.
    ///   - text: Two-way binding to the field's text.
    ///   - isFocused: Two-way binding reflecting/requesting first-responder focus.
    ///   - onSubmit: Invoked when Return is pressed.
    ///   - onEscape: Invoked when Escape is pressed.
    ///   - onMoveSelection: Invoked with a selection delta (e.g. -1/+1) for navigation.
    ///   - onUnhandledNavigationKey: Invoked for arrow keys the field does not consume; returns whether the host handled it.
    ///   - fieldEditorNavigationDelta: Maps a field-editor command selector and event to a selection delta, or nil.
    ///   - keyEventNavigationDelta: Maps a key event to a selection delta, or nil.
    ///   - shouldSubmitWithReturn: Returns whether a Return key event should submit.
    public init(
        placeholder: String,
        text: Binding<String>,
        isFocused: Binding<Bool>,
        onSubmit: @escaping () -> Void,
        onEscape: @escaping () -> Void,
        onMoveSelection: @escaping (Int) -> Void,
        onUnhandledNavigationKey: @escaping (NSEvent) -> Bool,
        fieldEditorNavigationDelta: @escaping (Selector, NSEvent?) -> Int?,
        keyEventNavigationDelta: @escaping (NSEvent) -> Int?,
        shouldSubmitWithReturn: @escaping (NSEvent) -> Bool
    ) {
        self.placeholder = placeholder
        self._text = text
        self._isFocused = isFocused
        self.onSubmit = onSubmit
        self.onEscape = onEscape
        self.onMoveSelection = onMoveSelection
        self.onUnhandledNavigationKey = onUnhandledNavigationKey
        self.fieldEditorNavigationDelta = fieldEditorNavigationDelta
        self.keyEventNavigationDelta = keyEventNavigationDelta
        self.shouldSubmitWithReturn = shouldSubmitWithReturn
    }

    @MainActor public final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CommandPaletteSearchFieldRepresentable
        var isProgrammaticMutation = false
        weak var parentField: CommandPaletteNativeTextField?
        var pendingFocusRequest: Bool?
        nonisolated(unsafe) var editorTextDidChangeObserver: (any NSObjectProtocol)?
        weak var observedEditor: NSTextView?

        init(parent: CommandPaletteSearchFieldRepresentable) {
            self.parent = parent
        }

        deinit { editorTextDidChangeObserver.map(NotificationCenter.default.removeObserver) }

        public func controlTextDidChange(_ obj: Notification) {
            guard !isProgrammaticMutation else { return }
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        public func controlTextDidBeginEditing(_ obj: Notification) {
            if let field = obj.object as? NSTextField,
               let editor = field.currentEditor() as? NSTextView {
                attachEditorTextDidChangeObserverIfNeeded(editor)
            }
            if !parent.isFocused {
                DispatchQueue.main.async {
                    self.parent.isFocused = true
                }
            }
        }

        public func controlTextDidEndEditing(_ obj: Notification) {
            detachEditorTextDidChangeObserver()
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if let delta = parent.fieldEditorNavigationDelta(commandSelector, NSApp.currentEvent) {
                parent.onMoveSelection(delta); return true
            }

            switch commandSelector {
            case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveUp(_:)):
                return NSApp.currentEvent.map(parent.onUnhandledNavigationKey) ?? false
            case #selector(NSResponder.insertNewline(_:)):
                guard !textView.hasMarkedText() else { return false }
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                guard !textView.hasMarkedText() else { return false }
                parent.onEscape()
                return true
            default:
                return false
            }
        }

        func handleKeyEvent(_ event: NSEvent, editor: NSTextView?) -> Bool {
            guard !(editor?.hasMarkedText() ?? false) else { return false }

            if let delta = parent.keyEventNavigationDelta(event) {
                parent.onMoveSelection(delta)
                return true
            }

            if parent.shouldSubmitWithReturn(event) {
                parent.onSubmit()
                return true
            }

            if event.keyCode == 53,
               event.modifierFlags
                .intersection(.deviceIndependentFlagsMask)
                .subtracting([.numericPad, .function, .capsLock])
                .isEmpty {
                parent.onEscape()
                return true
            }

            return false
        }

        func attachEditorTextDidChangeObserverIfNeeded(_ editor: NSTextView) {
            if observedEditor !== editor {
                detachEditorTextDidChangeObserver()
            }
            guard editorTextDidChangeObserver == nil else { return }
            observedEditor = editor
            editorTextDidChangeObserver = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification,
                object: editor,
                queue: .main
            ) { [weak self, weak editor] _ in
                MainActor.assumeIsolated { if let self, !self.isProgrammaticMutation, let editor { self.parent.text = editor.string } }
            }
        }

        func detachEditorTextDidChangeObserver() {
            if let editorTextDidChangeObserver {
                NotificationCenter.default.removeObserver(editorTextDidChangeObserver)
                self.editorTextDidChangeObserver = nil
            }
            observedEditor = nil
        }
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    public func makeNSView(context: Context) -> CommandPaletteNativeTextField {
        let field = CommandPaletteNativeTextField(frame: .zero)
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = placeholder
        field.setAccessibilityIdentifier("CommandPaletteSearchField")
        field.delegate = context.coordinator
        field.stringValue = text
        field.isEditable = true
        field.isSelectable = true
        field.isEnabled = true
        field.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        context.coordinator.parentField = field
        return field
    }

    public func updateNSView(_ nsView: CommandPaletteNativeTextField, context: Context) {
        context.coordinator.parent = self
        context.coordinator.parentField = nsView
        nsView.placeholderString = placeholder

        if let editor = nsView.currentEditor() as? NSTextView {
            context.coordinator.attachEditorTextDidChangeObserverIfNeeded(editor)
            if editor.string != text, !editor.hasMarkedText() {
                context.coordinator.isProgrammaticMutation = true
                editor.string = text
                nsView.stringValue = text
                context.coordinator.isProgrammaticMutation = false
            }
        } else if nsView.stringValue != text {
            context.coordinator.detachEditorTextDidChangeObserver()
            nsView.stringValue = text
        } else {
            context.coordinator.detachEditorTextDidChangeObserver()
        }

        guard let window = nsView.window else { return }
        let firstResponder = window.firstResponder
        let isFirstResponder =
            firstResponder === nsView ||
            nsView.currentEditor() != nil ||
            ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView

        if isFocused, !isFirstResponder, context.coordinator.pendingFocusRequest != true {
            context.coordinator.pendingFocusRequest = true
            DispatchQueue.main.async { [weak nsView, weak coordinator = context.coordinator] in
                coordinator?.pendingFocusRequest = nil
                guard let coordinator, coordinator.parent.isFocused else { return }
                guard let nsView, let window = nsView.window else { return }
                let firstResponder = window.firstResponder
                let alreadyFocused =
                    firstResponder === nsView ||
                    nsView.currentEditor() != nil ||
                    ((firstResponder as? NSTextView)?.delegate as? NSTextField) === nsView
                guard !alreadyFocused else { return }
                window.makeFirstResponder(nsView)
            }
        }
    }

    public static func dismantleNSView(_ nsView: CommandPaletteNativeTextField, coordinator: Coordinator) {
        nsView.delegate = nil
        nsView.onHandleKeyEvent = nil
        coordinator.detachEditorTextDidChangeObserver()
        coordinator.parentField = nil
    }
}
