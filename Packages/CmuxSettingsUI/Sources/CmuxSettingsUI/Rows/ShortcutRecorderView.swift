import AppKit
import CmuxSettings
import SwiftUI

/// AppKit-backed SwiftUI control that records one ``ShortcutStroke``.
///
/// SwiftUI does not surface raw key-down events with modifier flags
/// usable for shortcut recording, so this view wraps an
/// `NSViewRepresentable` over a focusable `NSView` subclass that
/// captures `keyDown` and `flagsChanged`. Click the view to focus it;
/// the next keystroke is captured and yielded via ``onStroke``.
public struct ShortcutRecorderView: NSViewRepresentable {
    private let onStroke: (ShortcutStroke) -> Void
    private let placeholder: String

    /// Creates a recorder.
    ///
    /// - Parameters:
    ///   - placeholder: Text shown when no key has been captured yet.
    ///   - onStroke: Called once per captured keystroke with the typed
    ///     value. Caller is responsible for storing it.
    public init(placeholder: String = "Click and press a shortcut", onStroke: @escaping (ShortcutStroke) -> Void) {
        self.placeholder = placeholder
        self.onStroke = onStroke
    }

    public func makeNSView(context: Context) -> RecorderHostView {
        let view = RecorderHostView()
        view.placeholder = placeholder
        view.onStroke = onStroke
        return view
    }

    public func updateNSView(_ nsView: RecorderHostView, context: Context) {
        nsView.placeholder = placeholder
        nsView.onStroke = onStroke
    }
}

/// Focusable AppKit host view for ``ShortcutRecorderView``.
public final class RecorderHostView: NSView {
    public var placeholder: String = ""
    public var onStroke: ((ShortcutStroke) -> Void)?

    private let label = NSTextField(labelWithString: "")

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
        ])
        refreshLabel(with: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var acceptsFirstResponder: Bool { true }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        layer?.borderColor = NSColor.separatorColor.cgColor
        return result
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    public override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        let stroke = ShortcutStroke(
            key: chars.lowercased(),
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control),
            keyCode: event.keyCode
        )
        refreshLabel(with: stroke)
        onStroke?(stroke)
    }

    private func refreshLabel(with stroke: ShortcutStroke?) {
        guard let stroke else {
            label.stringValue = placeholder
            return
        }
        var parts: [String] = []
        if stroke.control { parts.append("⌃") }
        if stroke.option { parts.append("⌥") }
        if stroke.shift { parts.append("⇧") }
        if stroke.command { parts.append("⌘") }
        parts.append(stroke.key.uppercased())
        label.stringValue = parts.joined()
    }
}
