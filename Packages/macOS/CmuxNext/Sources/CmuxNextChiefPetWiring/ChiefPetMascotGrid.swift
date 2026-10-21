import AppKit
import CmuxNextDesign
import CmuxNextFloating

/// The Chief pet's nine characters side by side in the Chief Settings popover (Leo 2026-10-21:
/// "the nine avatars, we need to be able to just swap them out, just how ChatGPT does"): each
/// character's picture, its name as the tooltip and VoiceOver label, the current one checked.
/// One click picks a character; `onPick` writes it.
@MainActor
final class ChiefPetMascotGrid: NSStackView {
    static let columns = 5
    /// What a click on a character runs, with the character's id (`home.chiefPetMascot`).
    var onPick: ((String) -> Void)?
    private(set) var cells: [ChiefPetMascotCell] = []

    init(items: [(id: String, title: String)]) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = Metrics.space1
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(ChiefPetMascot.pickerTitle)
        setAccessibilityIdentifier("cmux.home.chief.petMascot")
        cells = items.map { item in
            let cell = ChiefPetMascotCell(id: item.id, title: item.title)
            cell.target = self
            cell.action = #selector(picked(_:))
            return cell
        }
        for start in stride(from: 0, to: cells.count, by: Self.columns) {
            let row = NSStackView(views: Array(cells[start..<min(start + Self.columns, cells.count)]))
            row.orientation = .horizontal
            row.spacing = Metrics.space1
            addArrangedSubview(row)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Checks the character `id` (an unknown id: the first, as the Settings page shows it).
    func select(_ id: String, enabled: Bool) {
        let shown = cells.contains { $0.id == id } ? id : cells.first?.id
        for cell in cells {
            cell.isSelected = cell.id == shown
            cell.isEnabled = enabled
        }
    }

    var selectedID: String? { cells.first { $0.isSelected }?.id }

    @objc private func picked(_ sender: ChiefPetMascotCell) {
        select(sender.id, enabled: true)  // checked at once; the settings watch confirms it
        onPick?(sender.id)
    }
}

/// One character in the grid: its picture on the chrome's hover, pressed and selected fills.
@MainActor
final class ChiefPetMascotCell: NSButton {
    static let side: CGFloat = 28
    static let pictureSide: CGFloat = 22
    let id: String
    private lazy var hover = ChromeHover(self, behindContent: true)

    /// Set again after every click: a push-on-push-off click flips `state` itself, so a click on
    /// the checked character must put it back on.
    var isSelected = false {
        didSet {
            state = isSelected ? .on : .off
            hover.state.selected = isSelected
            needsDisplay = true
        }
    }

    override var isEnabled: Bool {
        didSet { alphaValue = isEnabled ? 1 : 0.5 }
    }

    init(id: String, title: String) {
        self.id = id
        super.init(frame: .zero)
        setAccessibilityLabel(title)
        self.title = ""
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.pushOnPushOff)
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        image = ChiefPetMascot(rawValue: id)?.image.map { ChiefPetSettingsRows.thumbnail($0, side: Self.pictureSide) }
        image?.accessibilityDescription = title
        state = .off
        setAccessibilityRole(.radioButton)
        setAccessibilityIdentifier("cmux.home.chief.petMascot.\(id)")
        themedToolTip = title
        focusRingType = .default
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
        hover.followPointer(isHoverable: { [weak self] in self?.isEnabled ?? false }, onChange: { [weak self] in self?.needsDisplay = true })
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func resetCursorRects() {
        guard isEnabled else { return }
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    nonisolated override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        hover.refresh(animated: false)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return super.mouseDown(with: event) }
        hover.state.pressed = true
        defer { hover.state.pressed = false }
        super.mouseDown(with: event)
    }

    override func viewDidHide() {
        super.viewDidHide()
        hover.state.pressed = false
        hover.pointer?.refresh()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        hover.pointer?.refresh()
    }
}
