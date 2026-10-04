import AppKit
import CmuxHomeCore
import UniformTypeIdentifiers

/// The draft attachments above the compose text: a thumbnail per image or
/// video, an icon and name per file, each with a remove button. Chips sit
/// left to right in the order they arrived; the tray clips at its width.
final class HomeDraftTrayView: NSView {
    /// Remove the draft with this content hash.
    var onRemove: (String) -> Void = { _ in }
    private var chips: [(hash: String, view: NSView)] = []

    static let height: CGFloat = 60
    static let chipSide: CGFloat = 52
    static let fileWidth: CGFloat = 150
    static let spacing: CGFloat = 8

    override var isFlipped: Bool { true }

    func show(_ drafts: [HomeDraftAttachment]) {
        chips.forEach { $0.view.removeFromSuperview() }
        chips = drafts.map { draft in
            let chip = makeChip(draft)
            addSubview(chip)
            return (draft.ref.hash, chip)
        }
        needsLayout = true
    }

    /// A chip's frame in this view's coordinates (the send morph starts there).
    func chipFrame(_ hash: String) -> CGRect? {
        chips.first { $0.hash == hash }?.view.frame
    }

    override func layout() {
        super.layout()
        var x: CGFloat = 0
        for (_, view) in chips {
            let width = view.identifier?.rawValue == "file" ? Self.fileWidth : Self.chipSide
            view.frame = CGRect(x: x, y: (bounds.height - Self.chipSide) / 2, width: width, height: Self.chipSide)
            x += width + Self.spacing
        }
    }

    private func makeChip(_ draft: HomeDraftAttachment) -> NSView {
        let chip = NSView()
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 10
        chip.layer?.masksToBounds = true
        chip.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        if let thumbnail = draft.thumbnail {
            chip.identifier = NSUserInterfaceItemIdentifier("media")
            chip.layer?.contents = thumbnail
            chip.layer?.contentsGravity = .resizeAspectFill
        } else {
            chip.identifier = NSUserInterfaceItemIdentifier("file")
            let type = UTType(mimeType: draft.ref.mimeType) ?? UTType(filenameExtension: (draft.ref.name as NSString).pathExtension) ?? .data
            let icon = NSImageView(image: NSWorkspace.shared.icon(for: type))
            icon.frame = CGRect(x: 6, y: 8, width: 36, height: 36)
            chip.addSubview(icon)
            let name = NSTextField(labelWithString: draft.ref.name)
            name.font = .systemFont(ofSize: 11, weight: .medium)
            name.lineBreakMode = .byTruncatingMiddle
            name.frame = CGRect(x: 46, y: 18, width: Self.fileWidth - 70, height: 16)
            chip.addSubview(name)
        }
        chip.setAccessibilityElement(true)
        chip.setAccessibilityRole(.group)
        chip.setAccessibilityLabel(draft.ref.name)
        let remove = HomeTrayRemoveButton(hash: draft.ref.hash) { [weak self] hash in self?.onRemove(hash) }
        remove.frame = CGRect(x: (draft.thumbnail == nil ? Self.fileWidth : Self.chipSide) - 20, y: 2, width: 18, height: 18)
        chip.addSubview(remove)
        return chip
    }
}

/// The small remove button on a draft chip.
final class HomeTrayRemoveButton: NSButton {
    private let draftHash: String
    private let onRemove: (String) -> Void

    init(hash: String, onRemove: @escaping (String) -> Void) {
        draftHash = hash
        self.onRemove = onRemove
        super.init(frame: .zero)
        isBordered = false
        image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: HomeStrings.removeAttachment)
        contentTintColor = .secondaryLabelColor
        imageScaling = .scaleProportionallyUpOrDown
        setAccessibilityLabel(HomeStrings.removeAttachment)
        toolTip = HomeStrings.removeAttachment
        target = self
        action = #selector(removeClicked)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func removeClicked() { onRemove(draftHash) }
}
