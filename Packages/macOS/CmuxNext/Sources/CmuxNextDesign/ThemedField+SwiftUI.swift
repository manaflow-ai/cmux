public import AppKit
public import SwiftUI

/// SwiftUI's text field in the theme: a `ThemedTextField` (or `ThemedSecureTextField`) in a
/// `ThemedFieldBox`, for the panes whose `.roundedBorder` fields drew AppKit's bezel, text and gray
/// placeholder whatever the room's theme. Return calls `onSubmit`; Up and Down call `onMove` with
/// -1 and 1 when it is set (a results list under a search field) and move the caret otherwise.
/// Without its box (`boxed` false) it is the bare themed field (text, caret and hint in the
/// scope's inks) for a `.plain` field in the caller's own container.
public struct ThemedField: NSViewRepresentable {
    @Binding private var text: String
    private let placeholder: String?
    private let secure: Bool
    private let font: NSFont
    private let height: CGFloat
    private let focusOnAppear: Bool
    private let boxed: Bool
    private let isFocused: Binding<Bool>?
    private let identifier: String?
    private let onSubmit: @MainActor () -> Void
    private let onMove: (@MainActor (Int) -> Void)?
    private let onCancel: (@MainActor () -> Void)?

    /// - Parameters:
    ///   - text: The field's text.
    ///   - placeholder: The hint shown while it is empty, in the scope's hint ink.
    ///   - secure: A secure field: its characters never reach the screen or the pasteboard. Read
    ///     once, when the field is made; a later value doesn't swap the field.
    ///   - font: The text's font.
    ///   - height: The box's height; a change resizes it.
    ///   - focusOnAppear: Takes the keyboard each time it appears in a window (its tab shown again
    ///     too), as an `.onAppear` focus does.
    ///   - boxed: Draws the theme's field fill and hairline; false leaves the container to the caller.
    ///   - isFocused: Whether the field has the keyboard: true gives it the keyboard, false takes it
    ///     away, and the field writes its own changes back (as SwiftUI's `.focused` does).
    ///   - identifier: The field's accessibility identifier.
    ///   - onSubmit: Return.
    ///   - onMove: Up (-1) and Down (1); nil leaves them to the field.
    ///   - onCancel: Escape; nil leaves it to the field.
    public init(text: Binding<String>, placeholder: String? = nil, secure: Bool = false, font: NSFont = Typography.body,
                height: CGFloat = Metrics.controlHeight, focusOnAppear: Bool = false, boxed: Bool = true,
                isFocused: Binding<Bool>? = nil, identifier: String? = nil,
                onSubmit: @escaping @MainActor () -> Void = {}, onMove: (@MainActor (Int) -> Void)? = nil,
                onCancel: (@MainActor () -> Void)? = nil) {
        _text = text
        self.placeholder = placeholder
        self.secure = secure
        self.font = font
        self.height = height
        self.focusOnAppear = focusOnAppear
        self.boxed = boxed
        self.isFocused = isFocused
        self.identifier = identifier
        self.onSubmit = onSubmit
        self.onMove = onMove
        self.onCancel = onCancel
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> ThemedFieldHost {
        let field: NSTextField = secure ? ThemedSecureTextField() : ThemedTextField()
        (field as? ThemedTextField)?.fill = { Palette.chromeBackground }
        (field as? ThemedSecureTextField)?.fill = { Palette.chromeBackground }
        field.delegate = context.coordinator
        let host = ThemedFieldHost(box: ThemedFieldBox(field: field, height: height, drawsChrome: boxed))
        host.box.onEditingChange = { [weak coordinator = context.coordinator] editing in coordinator?.editingChanged(editing) }
        host.focusOnAppear = focusOnAppear || isFocused?.wrappedValue == true
        return host
    }

    public func updateNSView(_ host: ThemedFieldHost, context: Context) {
        context.coordinator.parent = self
        let field = host.box.field
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        // The placeholder names the field for VoiceOver, as a stock field's title does, also once
        // it holds text and the hint is gone.
        if field.accessibilityLabel() != placeholder { field.setAccessibilityLabel(placeholder) }
        if field.font != font { field.font = font }
        if let identifier, field.accessibilityIdentifier() != identifier { field.setAccessibilityIdentifier(identifier) }
        host.box.height = height
        host.focusOnAppear = focusOnAppear || isFocused?.wrappedValue == true
        guard let isFocused, let window = host.window else { return }
        let editing = field.currentEditor() != nil
        if isFocused.wrappedValue, !editing {
            window.makeFirstResponder(field)
        } else if !isFocused.wrappedValue, editing {
            window.makeFirstResponder(nil)
        }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: ThemedFieldHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? Metrics.controlHeight * 8, height: height)
    }

    /// Carries the field's edits to the binding and its Return, Up and Down to the callbacks.
    @MainActor public final class Coordinator: NSObject, NSTextFieldDelegate {
        fileprivate var parent: ThemedField

        fileprivate init(_ parent: ThemedField) { self.parent = parent }

        /// The field took the keyboard or let it go: an `isFocused` binding follows.
        fileprivate func editingChanged(_ editing: Bool) {
            guard let isFocused = parent.isFocused, isFocused.wrappedValue != editing else { return }
            isFocused.wrappedValue = editing
        }

        public func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.text = control.stringValue
                parent.onSubmit()
                return true
            case #selector(NSResponder.moveUp(_:)) where parent.onMove != nil:
                parent.onMove?(-1)
                return true
            case #selector(NSResponder.moveDown(_:)) where parent.onMove != nil:
                parent.onMove?(1)
                return true
            case #selector(NSResponder.cancelOperation(_:)) where parent.onCancel != nil:
                parent.onCancel?()
                return true
            default:
                return false
            }
        }
    }
}

/// `ThemedField`'s view: its box, and the keyboard each time it moves into a window when asked.
public final class ThemedFieldHost: NSView {
    public let box: ThemedFieldBox
    fileprivate var focusOnAppear = false

    fileprivate init(box: ThemedFieldBox) {
        self.box = box
        super.init(frame: .zero)
        addSubview(box)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") } // crash-allow: never decoded from a nib

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnAppear, let window, box.field.currentEditor() == nil else { return }
        window.makeFirstResponder(box.field)
    }
}
