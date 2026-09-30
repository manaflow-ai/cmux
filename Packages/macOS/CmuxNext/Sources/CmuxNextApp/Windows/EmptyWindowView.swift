import AppKit
import CmuxNextDesign
import Observation

/// Content of the only window when it lists no workspaces (its last one
/// closed or moved away): a short line and a "New Workspace" button. Other
/// windows never show it; they close instead (`WindowRegistry`).
final class EmptyWindowView: NSView {
    var onNewWorkspace: (() -> Void)?
    private let label = NSTextField(labelWithString: WindowStrings.emptyTitle)
    private let button = NSButton(title: WindowStrings.newWorkspace, target: nil, action: nil)
    private var tokenObservation: Task<Void, Never>?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.textColor = Palette.textSecondary
        label.alignment = .center
        button.bezelStyle = .push
        button.controlSize = .regular
        button.target = self
        button.action = #selector(newWorkspace)
        button.setAccessibilityIdentifier("cmux.emptyWindow.newWorkspace")
        let stack = NSStackView(views: [label, button])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = Metrics.space5
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        tokenObservation = Task { [weak self] in
            for await _ in Observations({ Metrics.density }) {
                self?.label.font = Typography.body
                self?.button.font = Typography.body
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    isolated deinit {
        tokenObservation?.cancel()
    }

    @objc private func newWorkspace() { onNewWorkspace?() }
}
