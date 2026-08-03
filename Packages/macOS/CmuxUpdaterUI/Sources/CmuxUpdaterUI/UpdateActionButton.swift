import AppKit

/// AppKit target-action button backed by an actor-confined closure.
@MainActor
final class UpdateActionButton: NSButton {
    private let handler: @MainActor () -> Void

    init(
        title: String,
        bezelStyle: NSButton.BezelStyle = .rounded,
        keyEquivalent: String = "",
        handler: @MainActor @escaping () -> Void
    ) {
        self.handler = handler
        super.init(frame: .zero)
        self.title = title
        self.bezelStyle = bezelStyle
        self.keyEquivalent = keyEquivalent
        controlSize = .small
        target = self
        action = #selector(invokeHandler)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func invokeHandler() {
        handler()
    }
}
