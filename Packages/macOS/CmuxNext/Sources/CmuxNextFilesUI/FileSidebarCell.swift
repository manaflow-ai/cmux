import AppKit
import CmuxNextDesign
import CmuxNextFiles

/// A sidebar row's view: symbol and name, a bold title for headers, and an
/// Eject button for ejectable volumes.
final class FileSidebarCell: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("FileSidebarCell")
    private let symbol = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let ejectButton = NSButton()
    private var onEject: (() -> Void)?

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.lineBreakMode = .byTruncatingMiddle
        ejectButton.image = NSImage(systemSymbolName: "eject", accessibilityDescription: FilesStrings.eject)
        ejectButton.isBordered = false
        ejectButton.setAccessibilityLabel(FilesStrings.eject)
        ejectButton.target = self
        ejectButton.action = #selector(eject)
        let stack = NSStackView(views: [symbol, label, ejectButton])
        stack.spacing = Metrics.space2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 16),
        ])
        imageView = symbol
        textField = label
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Shows `row`; `eject` runs when its Eject button is clicked.
    func show(_ row: FileSidebarRow, eject: @escaping (SidebarVolume) -> Void) {
        ejectButton.isHidden = true
        onEject = nil
        switch row {
        case .header(let title):
            symbol.isHidden = true
            label.stringValue = title
            label.font = Typography.system(size: TypeScale.caption, weight: .semibold)
            label.textColor = .secondaryLabelColor
        case .favorite(_, let name, let symbolName):
            show(name, symbolName: symbolName)
        case .volume(let volume, let symbolName):
            show(volume.name, symbolName: symbolName)
            if volume.isEjectable {
                ejectButton.isHidden = false
                onEject = { eject(volume) }
            }
        }
    }

    private func show(_ name: String, symbolName: String) {
        symbol.isHidden = false
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbol.contentTintColor = .secondaryLabelColor
        label.stringValue = name
        label.font = Typography.system(size: TypeScale.body)
        label.textColor = .labelColor
    }

    @objc private func eject() { onEject?() }
}
