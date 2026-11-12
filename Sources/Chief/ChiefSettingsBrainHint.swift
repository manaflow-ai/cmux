import AppKit
import CmuxChief

/// The quiet brain hint under the transcript header's name pill: "Opus 5.5 ·
/// Medium" at 10 pt in the tertiary color (evaluator P2: the compose bar has
/// no indication of which brain answers; `topics/composer.md` asks for a
/// quiet configuration row while the composer itself stays clean). The same
/// text goes into the pill's tooltip through ``onToolTip``.
///
/// It follows the `chief.*` settings from any entry point (this panel,
/// Settings, cmux.json) through `UserDefaults.didChangeNotification`, no polling.
@MainActor
final class ChiefSettingsBrainHint {
    /// The label the host adds over its transcript; it never takes clicks.
    let label = ChiefSettingsBrainHintLabel(labelWithString: "")
    /// The pill tooltip for the current hint.
    var onToolTip: (String) -> Void = { _ in } { didSet { onToolTip(ChiefSettingsStrings.pillToolTip(text)) } }
    private var observer: (any NSObjectProtocol)?
    private(set) var text = ""

    /// Just below the pill (`PaneHeaderView.pillCenterY` 58 + half its 28 pt height).
    static let top: CGFloat = 73

    init() {
        label.font = .systemFont(ofSize: 10)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityIdentifier("ChiefBrainHint")
        update()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() } // main-proof: observer on queue: .main
        }
    }

    // Not an isolated deinit (Swift 6.0 has none): the main-thread check guards the hop.
    deinit {
        guard Thread.isMainThread else { return } // main-proof: returns off the main thread
        MainActor.assumeIsolated {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
    }

    func apply(_ theme: ChiefTheme) {
        label.textColor = theme.textTertiary
    }

    /// Centers the label under the pill across `transcriptFrame`.
    func layout(in transcriptFrame: CGRect) {
        let frame = frame(in: transcriptFrame)
        if label.frame != frame { label.frame = frame }
    }

    /// The label's place for `transcriptFrame` (the host animates to it with the settings panel).
    func frame(in transcriptFrame: CGRect) -> CGRect {
        let height = ceil(label.intrinsicContentSize.height)
        return CGRect(x: transcriptFrame.minX + 16, y: transcriptFrame.minY + Self.top,
                      width: max(0, transcriptFrame.width - 32), height: height)
    }

    /// Re-reads the settings (written by any entry point) and shows them.
    private func update() {
        let hint = ChiefSettingsStrings.brainHint(ChiefSettingsAccess().current)
        guard hint != text else { return }
        text = hint
        label.stringValue = hint
        label.setAccessibilityLabel(ChiefSettingsStrings.pillToolTip(hint))
        onToolTip(ChiefSettingsStrings.pillToolTip(hint))
    }
}

/// A label that lets clicks through to the header below it (the window drag, the avatar).
final class ChiefSettingsBrainHintLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
