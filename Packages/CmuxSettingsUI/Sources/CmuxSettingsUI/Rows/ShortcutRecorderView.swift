import AppKit
import CmuxSettings
import SwiftUI

/// AppKit-backed SwiftUI control that records a ``StoredShortcut``.
///
/// SwiftUI does not surface raw key-down events with modifier flags
/// usable for shortcut recording, so this view wraps an
/// `NSViewRepresentable` over a focusable `NSView` subclass that
/// captures `keyDown` and `flagsChanged`. Click the view to focus it;
/// the next keystroke is captured and yielded via ``onStroke``.
///
/// When ``chordsEnabled`` is `true`, the recorder collects two
/// keystrokes in sequence — the second is the "chord" stroke,
/// modeled after tmux-style `Ctrl-B + p` bindings — and yields a
/// chorded ``StoredShortcut`` via ``onChord``. Pressing Escape during
/// the chord-pending state aborts the recording.
public struct ShortcutRecorderView: NSViewRepresentable {
    private let onStroke: (ShortcutStroke) -> Void
    private let onChord: ((StoredShortcut) -> Void)?
    private let placeholder: String
    private let chordsEnabled: Bool

    /// Creates a single-stroke recorder.
    public init(
        placeholder: String = "Click and press a shortcut",
        onStroke: @escaping (ShortcutStroke) -> Void
    ) {
        self.placeholder = placeholder
        self.onStroke = onStroke
        self.onChord = nil
        self.chordsEnabled = false
    }

    /// Creates a recorder that can capture either a single stroke or
    /// a two-stroke chord. When the user enters chord mode, the
    /// recorder waits for a second keystroke and yields it via
    /// ``onChord``. Plain single-key recordings still fire
    /// ``onStroke``.
    public init(
        placeholder: String = "Click and press a shortcut",
        chordsEnabled: Bool,
        onStroke: @escaping (ShortcutStroke) -> Void,
        onChord: @escaping (StoredShortcut) -> Void
    ) {
        self.placeholder = placeholder
        self.onStroke = onStroke
        self.onChord = onChord
        self.chordsEnabled = chordsEnabled
    }

    public func makeNSView(context: Context) -> RecorderHostView {
        let view = RecorderHostView()
        view.placeholder = placeholder
        view.chordsEnabled = chordsEnabled
        view.onStroke = onStroke
        view.onChord = onChord
        return view
    }

    public func updateNSView(_ nsView: RecorderHostView, context: Context) {
        nsView.placeholder = placeholder
        nsView.chordsEnabled = chordsEnabled
        nsView.onStroke = onStroke
        nsView.onChord = onChord
    }
}

/// Focusable AppKit host view for ``ShortcutRecorderView``.
public final class RecorderHostView: NSView {
    public var placeholder: String = ""
    public var chordsEnabled: Bool = false
    public var onStroke: ((ShortcutStroke) -> Void)?
    public var onChord: ((StoredShortcut) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var pendingFirst: ShortcutStroke?

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
        refreshLabel()
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
        pendingFirst = nil
        refreshLabel()
        return result
    }

    public override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    public override func keyDown(with event: NSEvent) {
        // Escape aborts a chord-in-progress without committing.
        if event.keyCode == 53 /* Escape */ {
            pendingFirst = nil
            refreshLabel()
            return
        }

        guard let chars = event.charactersIgnoringModifiers, !chars.isEmpty else { return }
        let stroke = ShortcutStroke(
            key: chars.lowercased(),
            command: event.modifierFlags.contains(.command),
            shift: event.modifierFlags.contains(.shift),
            option: event.modifierFlags.contains(.option),
            control: event.modifierFlags.contains(.control),
            keyCode: event.keyCode
        )

        if chordsEnabled, let first = pendingFirst {
            // Second stroke commits the chord.
            pendingFirst = nil
            let chord = StoredShortcut(first: first, second: stroke)
            refreshLabel(chord: chord)
            onChord?(chord)
            return
        }

        if chordsEnabled, pendingFirst == nil {
            // First stroke goes into pending; wait for the second.
            pendingFirst = stroke
            refreshLabel(pendingFirst: stroke)
            return
        }

        // Single-stroke recording.
        refreshLabel(single: stroke)
        onStroke?(stroke)
    }

    private func refreshLabel() {
        label.stringValue = placeholder
    }

    private func refreshLabel(single stroke: ShortcutStroke) {
        label.stringValue = display(stroke)
    }

    private func refreshLabel(pendingFirst stroke: ShortcutStroke) {
        label.stringValue = "\(display(stroke)) …"
    }

    private func refreshLabel(chord: StoredShortcut) {
        let first = display(chord.first)
        if let second = chord.second {
            label.stringValue = "\(first)  \(display(second))"
        } else {
            label.stringValue = first
        }
    }

    private func display(_ stroke: ShortcutStroke) -> String {
        var parts: [String] = []
        if stroke.control { parts.append("⌃") }
        if stroke.option { parts.append("⌥") }
        if stroke.shift { parts.append("⇧") }
        if stroke.command { parts.append("⌘") }
        parts.append(stroke.key.uppercased())
        return parts.joined()
    }
}
