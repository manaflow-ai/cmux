#if DEBUG
import AppKit

/// DEBUG ONLY (Environment Secrets Playground): a segmented control that runs a closure with the picked index.
final class EnvSegmented: NSSegmentedControl {
    private let onPick: @MainActor (Int) -> Void

    /// - Parameters:
    ///   - labels: one segment per label.
    ///   - selected: the picked segment's index.
    ///   - onPick: what picking a segment runs, with its index.
    init(_ labels: [String], selected: Int, onPick: @escaping @MainActor (Int) -> Void = { _ in }) {
        self.onPick = onPick
        super.init(frame: .zero)
        segmentCount = labels.count
        for (index, label) in labels.enumerated() { setLabel(label, forSegment: index) }
        trackingMode = .selectOne
        selectedSegment = selected
        segmentDistribution = .fillEqually
        target = self
        action = #selector(pick)
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func pick() { onPick(selectedSegment) }
}
#endif
