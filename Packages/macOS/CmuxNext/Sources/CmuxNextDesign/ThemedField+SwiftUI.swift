public import AppKit
public import SwiftUI

/// SwiftUI's text field in the theme: a `ThemedTextField` (or `ThemedSecureTextField`) in a
/// `ThemedFieldBox`, for the panes whose `.roundedBorder` fields drew AppKit's bezel, text and gray
/// placeholder whatever the room's theme. Return calls `onSubmit`; Up and Down call `onMove` with
/// -1 and 1 when it is set (a results list under a search field) and move the caret otherwise.
public struct ThemedField: NSViewRepresentable {
    @Binding private var text: String
    private let placeholder: String?
    private let secure: Bool
    private let font: NSFont
    private let height: CGFloat
    private let focusOnAppear: Bool
    private let identifier: String?
    private let onSubmit: @MainActor () -> Void
    private let onMove: (@MainActor (Int) -> Void)?

    /// - Parameters:
    ///   - text: The field's text.
    ///   - placeholder: The hint shown while it is empty, in the scope's hint ink.
    ///   - secure: A secure field: its characters never reach the screen or the pasteboard.
    ///   - font: The text's font.
    ///   - height: The box's height.
    ///   - focusOnAppear: Takes the keyboard when it first appears in a window.
    ///   - identifier: The field's accessibility identifier.
    ///   - onSubmit: Return.
    ///   - onMove: Up (-1) and Down (1); nil leaves them to the field.
    public init(text: Binding<String>, placeholder: String? = nil, secure: Bool = false, font: NSFont = Typography.body,
                height: CGFloat = Metrics.tabHeight, focusOnAppear: Bool = false, identifier: String? = nil,
                onSubmit: @escaping @MainActor () -> Void = {}, onMove: (@MainActor (Int) -> Void)? = nil) {
        _text = text
        self.placeholder = placeholder
        self.secure = secure
        self.font = font
        self.height = height
        self.focusOnAppear = focusOnAppear
        self.identifier = identifier
        self.onSubmit = onSubmit
        self.onMove = onMove
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }

    public func makeNSView(context: Context) -> ThemedFieldHost {
        let field: NSTextField = secure ? ThemedSecureTextField() : ThemedTextField()
        (field as? ThemedTextField)?.fill = { Palette.chromeBackground }
        (field as? ThemedSecureTextField)?.fill = { Palette.chromeBackground }
        field.delegate = context.coordinator
        let host = ThemedFieldHost(box: ThemedFieldBox(field: field, height: height))
        host.focusOnAppear = focusOnAppear
        return host
    }

    public func updateNSView(_ host: ThemedFieldHost, context: Context) {
        context.coordinator.parent = self
        let field = host.box.field
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.font != font { field.font = font }
        if let identifier, field.accessibilityIdentifier() != identifier { field.setAccessibilityIdentifier(identifier) }
    }

    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: ThemedFieldHost, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? Metrics.tabHeight * 8, height: height)
    }

    /// Carries the field's edits to the binding and its Return, Up and Down to the callbacks.
    @MainActor public final class Coordinator: NSObject, NSTextFieldDelegate {
        fileprivate var parent: ThemedField

        fileprivate init(_ parent: ThemedField) { self.parent = parent }

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
            default:
                return false
            }
        }
    }
}

/// `ThemedField`'s view: its box, and the keyboard on first appearance when asked.
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
        guard focusOnAppear, let window else { return }
        focusOnAppear = false
        window.makeFirstResponder(box.field)
    }
}
