import AppKit

/// A small push button in the Memory Inspector that runs a closure.
final class ChiefMemoryActionButton: NSButton {
    private let run: @MainActor () -> Void

    init(_ title: String, run: @escaping @MainActor () -> Void) {
        self.run = run
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .push
        controlSize = .small
        target = self
        action = #selector(clicked)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func clicked() { run() }
}
