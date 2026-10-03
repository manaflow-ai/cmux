public import AppKit
import CmuxNextDesign

/// What the App offers on a terminal whose shell ended (the dead-tab
/// overlay): "Restart Shell Here" (`tab.restart`) and "Close" (`closeTab`).
/// A nil action hides its button (a daemon without `tab-restart-v1`).
public struct TerminalDeadTabActions {
    public var restart: (@MainActor () -> Void)?
    public var close: (@MainActor () -> Void)?

    public init(restart: (@MainActor () -> Void)? = nil, close: (@MainActor () -> Void)? = nil) {
        self.restart = restart
        self.close = close
    }

    var isEmpty: Bool { restart == nil && close == nil }
}

/// The overlay's buttons, above the status banner while the shell has
/// ended. Subtle gray, no accent, like the banner.
final class TerminalDeadTabBar: NSStackView {
    private let restartButton = TerminalDeadTabBar.button(
        ModuleResourceBundle.terminal.text("terminal.restart.button", defaultValue: "Restart Shell Here"), symbol: "arrow.clockwise")
    private let closeButton = TerminalDeadTabBar.button(
        ModuleResourceBundle.terminal.text("terminal.close.button", defaultValue: "Close"), symbol: "xmark")
    private var actions = TerminalDeadTabActions()

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        restartButton.target = self
        restartButton.action = #selector(restartClicked)
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        addArrangedSubview(restartButton)
        addArrangedSubview(closeButton)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Shown only while the shell has ended and the App gave an action.
    func update(exited: Bool, actions: TerminalDeadTabActions) {
        self.actions = actions
        restartButton.isHidden = actions.restart == nil
        closeButton.isHidden = actions.close == nil
        isHidden = !exited || actions.isEmpty
    }

    private static func button(_ title: String, symbol: String) -> NSButton {
        let button = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(),
                              target: nil, action: nil)
        button.imagePosition = .imageLeading
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: 12, weight: .medium)
        button.contentTintColor = NSColor(white: 0.85, alpha: 1)
        button.setAccessibilityLabel(title)
        return button
    }

    @objc private func restartClicked() { actions.restart?() }
    @objc private func closeClicked() { actions.close?() }
}
