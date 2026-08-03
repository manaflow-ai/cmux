import AppKit
import CmuxSimulator

@MainActor
final class SimulatorAccessibilityPagedTree: NSView {
    private static let pageSize = 50
    private let stack = NSStackView()
    private var rows = [SimulatorAccessibilityPresentationRow]()
    private var highlightedNodeID: String?
    private var onSelect: ((SimulatorAccessibilityNode) -> Void)?
    private var requestedPage = 0
    private var signature = ""

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        rows: [SimulatorAccessibilityPresentationRow],
        highlightedNodeID: String?,
        onSelect: @escaping (SimulatorAccessibilityNode) -> Void
    ) {
        self.rows = rows
        self.highlightedNodeID = highlightedNodeID
        self.onSelect = onSelect
        requestedPage = min(requestedPage, pageCount - 1)
        let nextSignature = "\(requestedPage)|\(highlightedNodeID ?? "")|" + rows.map {
            "\($0.node.id):\($0.node.label ?? ""): \($0.depth)"
        }.joined(separator: "|")
        guard nextSignature != signature else { return }
        signature = nextSignature
        rebuild()
    }

    private var pageCount: Int {
        max(1, (rows.count + Self.pageSize - 1) / Self.pageSize)
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { stack.removeArrangedSubview($0); $0.removeFromSuperview() }
        let start = requestedPage * Self.pageSize
        for row in rows[start..<min(start + Self.pageSize, rows.count)] {
            let button = SimulatorAccessibilityTreeRow(
                row: row,
                isHighlighted: highlightedNodeID == row.node.id,
                onSelect: { [weak self] in self?.onSelect?($0) }
            )
            stack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        guard pageCount > 1 else { return }
        let previous = SimulatorClosureButton(title: String(localized: simulatorStrings.previousPage)) {
            [weak self] in
            guard let self else { return }
            requestedPage = max(0, requestedPage - 1)
            signature = ""
            rebuild()
        }
        previous.isEnabled = requestedPage > 0
        let page = simulatorLabel(
            String(localized: simulatorStrings.accessibilityPage(requestedPage + 1, pageCount)),
            color: .secondaryLabelColor
        )
        let next = SimulatorClosureButton(title: String(localized: simulatorStrings.nextPage)) {
            [weak self] in
            guard let self else { return }
            requestedPage = min(pageCount - 1, requestedPage + 1)
            signature = ""
            rebuild()
        }
        next.isEnabled = requestedPage + 1 < pageCount
        stack.addArrangedSubview(simulatorRow([previous, page, next]))
    }
}
