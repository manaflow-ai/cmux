import CmuxFoundation
import AppKit

/// Debug-menu window for the shared, cross-tag default display that new DEBUG
/// cmux windows open on.
///
/// Reads and writes ``DevWindowDisplayDefault`` (persisted in the shared
/// `cmux.json` via ``CmuxSettings``, not `@AppStorage`, so the value applies to
/// every tagged dev build, not just this one). The same value is also settable
/// from `cmux window default-display`.
final class DevWindowDisplayDebugWindowController: ReleasingWindowController {
    static let shared = DevWindowDisplayDebugWindowController()

    private override init() {
        super.init()
    }

    override func makeWindow() -> NSWindow {
        let window = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 360),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "debug.devWindowDisplay.title", defaultValue: "Dev Window Display")
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isMovableByWindowBackground = true
        window.identifier = NSUserInterfaceItemIdentifier("cmux.devWindowDisplay")
        window.center()
        window.contentView = DevWindowDisplayDebugView(frame: window.contentRect(forFrameRect: window.frame))
        AppDelegate.shared?.applyWindowDecorations(to: window)
        return window
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @MainActor
    func show() {
        showManagedWindow()
    }
}

@MainActor
private final class DevWindowDisplayDebugView: NSView {
    private let displayStack = NSStackView()
    private let currentLabelView = NSTextField(labelWithString: "")
    private var current = AppDelegate.shared?.settingsRuntime.flatMap(DevWindowDisplayDefault.current)
    private var displays = NSScreen.screens.map(\.localizedName)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: String(
            localized: "debug.devWindowDisplay.title",
            defaultValue: "Dev Window Display"
        ))
        title.font = GlobalFontMagnification.systemFont(ofSize: 13, weight: .semibold)
        let description = NSTextField(wrappingLabelWithString: String(
            localized: "debug.devWindowDisplay.description",
            defaultValue: "New DEBUG cmux windows open on the selected display. Shared across all tagged dev builds; applied at window creation."
        ))
        description.font = GlobalFontMagnification.systemFont(ofSize: 12)
        description.textColor = .secondaryLabelColor

        displayStack.orientation = .vertical
        displayStack.alignment = .leading
        displayStack.spacing = 6
        let displayBox = NSBox()
        displayBox.boxType = .custom
        displayBox.titlePosition = .noTitle
        displayBox.contentViewMargins = NSSize(width: 8, height: 8)
        displayBox.contentView = displayStack

        let refresh = NSButton(
            title: String(localized: "debug.devWindowDisplay.refresh", defaultValue: "Refresh displays"),
            target: self,
            action: #selector(refreshDisplays)
        )
        let clear = NSButton(
            title: String(localized: "debug.devWindowDisplay.clear", defaultValue: "Clear (system default)"),
            target: self,
            action: #selector(clearSelection)
        )
        let actionRow = NSStackView(views: [refresh, NSView(), clear])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.distribution = .fill
        actionRow.spacing = 8

        currentLabelView.font = GlobalFontMagnification.systemFont(ofSize: 11)
        currentLabelView.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, description, displayBox, actionRow, currentLabelView, NSView()])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            description.widthAnchor.constraint(equalTo: stack.widthAnchor),
            displayBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            actionRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            currentLabelView.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        rebuildDisplayButtons()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func refreshDisplays() {
        displays = NSScreen.screens.map(\.localizedName)
        current = AppDelegate.shared?.settingsRuntime.flatMap(DevWindowDisplayDefault.current)
        rebuildDisplayButtons()
    }

    @objc private func clearSelection() {
        write(nil)
    }

    @objc private func chooseDisplay(_ sender: NSButton) {
        guard displays.indices.contains(sender.tag) else { return }
        write(displays[sender.tag])
    }

    private func rebuildDisplayButtons() {
        for view in displayStack.arrangedSubviews {
            displayStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for (index, name) in displays.enumerated() {
            let button = NSButton(
                title: name,
                target: self,
                action: #selector(chooseDisplay(_:))
            )
            button.tag = index
            button.setButtonType(.radio)
            button.state = current == name ? .on : .off
            button.bezelStyle = .inline
            button.isBordered = false
            displayStack.addArrangedSubview(button)
        }
        currentLabelView.stringValue = currentLabel
    }

    /// Optimistically reflect the selection, then persist it through the shared
    /// settings store. `nil` clears the value (system-default placement).
    private func write(_ name: String?) {
        current = name
        rebuildDisplayButtons()
        guard let runtime = AppDelegate.shared?.settingsRuntime else { return }
        Task { await DevWindowDisplayDefault.set(name, runtime: runtime) }
    }

    private var currentLabel: String {
        if let current {
            return String(
                format: String(localized: "debug.devWindowDisplay.current", defaultValue: "Current: %@"),
                current
            )
        }
        return String(localized: "debug.devWindowDisplay.currentNone", defaultValue: "Current: (system default)")
    }
}
