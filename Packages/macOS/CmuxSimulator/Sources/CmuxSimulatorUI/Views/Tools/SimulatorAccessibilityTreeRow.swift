import AppKit
import CmuxSimulator

@MainActor
final class SimulatorAccessibilityTreeRow: SimulatorClosureButton {
    init(
        row: SimulatorAccessibilityPresentationRow,
        isHighlighted: Bool,
        onSelect: @escaping (SimulatorAccessibilityNode) -> Void
    ) {
        super.init(frame: .zero)
        title = String(repeating: "  ", count: min(row.depth, 8))
            + (row.node.label ?? row.node.role ?? row.node.id)
        alignment = .left
        bezelStyle = .inline
        isBordered = false
        imagePosition = .imageTrailing
        if isHighlighted {
            image = NSImage(systemSymbolName: "scope", accessibilityDescription: title)
        }
        handler = { onSelect(row.node) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
