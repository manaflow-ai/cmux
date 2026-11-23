#if DEBUG
import AppKit

/// DEBUG ONLY (Environment Secrets Playground): a system push button that runs a closure. The playground's
/// buttons are sample controls: most run nothing.
final class EnvButton: NSButton {
    /// How the button looks.
    enum Look {
        /// The plain push button.
        case normal
        /// The accent-filled default action.
        case prominent
        /// A red destructive action.
        case destructive
    }

    private let onPress: @MainActor () -> Void

    /// - Parameters:
    ///   - title: the button's title.
    ///   - look: plain, accent (prominent) or red (destructive).
    ///   - symbol: an SF Symbol before the title.
    ///   - small: the small control size, as a row's inline buttons.
    ///   - onPress: what a click runs.
    init(_ title: String, look: Look = .normal, symbol: String? = nil, small: Bool = false,
         onPress: @escaping @MainActor () -> Void = {}) {
        self.onPress = onPress
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        setButtonType(.momentaryPushIn)
        controlSize = small ? .small : .regular
        font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        if let symbol {
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            imagePosition = .imageLeading
        }
        switch look {
        case .normal: break
        case .prominent: bezelColor = .controlAccentColor
        case .destructive: hasDestructiveAction = true; bezelColor = .systemRed
        }
        target = self
        action = #selector(press)
        setContentHuggingPriority(.required, for: .horizontal)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func press() { onPress() }
}
#endif
