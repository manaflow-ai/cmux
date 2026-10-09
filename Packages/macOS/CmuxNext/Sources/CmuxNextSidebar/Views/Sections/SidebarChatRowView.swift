import AppKit
import CmuxNextDesign

/// One All chats row in the picked design (``SidebarChatsDesign``): the shared item row (press,
/// hover fill, menu) with the glyph only in Quiet and a faint trailing text in Age and Project.
final class SidebarChatRowView: SidebarItemRowView {
    let meta = NSTextField(labelWithString: "")
    private(set) var design = SidebarChatsDesign.age

    override init(frame: NSRect) {
        super.init(frame: frame)
        meta.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        meta.lineBreakMode = .byTruncatingTail
        meta.alignment = .right
        addSubview(meta)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: SidebarChatsView.Row, design: SidebarChatsDesign, now: Date) {
        self.design = design
        configure(SidebarItemInfo(title: row.title, symbol: "bubble.left", icon: .agentChat, brand: row.brand), style: .builtIn)
        let text = design.meta(updatedAt: row.updatedAt, folder: row.folder, now: now)
        meta.stringValue = text.map { design == .project ? "· " + $0 : $0 } ?? ""
        meta.isHidden = text == nil
        performWithTheme { meta.textColor = Palette.textSecondary.withAlphaComponent(design == .age ? 0.7 : 1) }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        icon.isHidden = design != .quiet
        let textX = design == .quiet ? title.frame.minX : icon.frame.minX
        var titleFrame = title.frame
        titleFrame.size.width = max(0, titleFrame.maxX - textX)
        titleFrame.origin.x = textX
        guard !meta.isHidden else { title.frame = titleFrame; return }
        let size = meta.intrinsicContentSize
        let maxMeta = min(ceil(size.width), bounds.width * 0.4)
        let metaX = titleFrame.maxX - maxMeta
        meta.frame = NSRect(x: metaX, y: (bounds.height - size.height) / 2, width: maxMeta, height: size.height)
        if design == .project {
            // Title · project read as one line: the project follows the title's text.
            let titleWidth = min(ceil(title.intrinsicContentSize.width), max(0, titleFrame.width - maxMeta - Metrics.space1))
            titleFrame.size.width = titleWidth
            meta.frame.origin.x = titleFrame.maxX + Metrics.space1
            meta.alignment = .left
        } else {
            titleFrame.size.width = max(0, metaX - Metrics.space2 - titleFrame.minX)
            meta.alignment = .right
        }
        title.frame = titleFrame
    }
}
