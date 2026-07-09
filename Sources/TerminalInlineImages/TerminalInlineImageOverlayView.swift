import AppKit
import Foundation

struct TerminalInlineImageOverlayItem: Sendable {
    let annotation: TerminalInlineImageAnnotation
    let thumbnail: TerminalInlineImageThumbnail
}

@MainActor
final class TerminalInlineImageOverlayView: NSView {
    var openPreview: ((URL) -> Void)?
    private var thumbnailViews: [UUID: TerminalInlineImageThumbnailView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        isHidden = true
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(items: [TerminalInlineImageOverlayItem], metrics: KeyboardCopyModeGridMetrics?) {
        guard let metrics, !items.isEmpty else {
            clear()
            return
        }
        isHidden = false
        let ids = Set(items.map(\.annotation.id))
        for id in Array(thumbnailViews.keys) where !ids.contains(id) {
            if let view = thumbnailViews.removeValue(forKey: id) {
                view.removeFromSuperview()
            }
        }

        for layout in layouts(for: items, metrics: metrics) {
            let view = thumbnailViews[layout.item.annotation.id] ?? makeThumbnailView()
            thumbnailViews[layout.item.annotation.id] = view
            if view.superview == nil {
                addSubview(view)
            }
            view.configure(item: layout.item)
            view.frame = layout.frame
        }
    }

    func clear() {
        for view in thumbnailViews.values {
            view.removeFromSuperview()
        }
        thumbnailViews.removeAll()
        isHidden = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        for view in subviews.reversed() {
            let converted = convert(point, to: view)
            if let hit = view.hitTest(converted) {
                return hit
            }
        }
        return nil
    }

    private func makeThumbnailView() -> TerminalInlineImageThumbnailView {
        let view = TerminalInlineImageThumbnailView(frame: .zero)
        view.openPreview = { [weak self] url in
            self?.openPreview?(url)
        }
        return view
    }

    private func layouts(
        for items: [TerminalInlineImageOverlayItem],
        metrics: KeyboardCopyModeGridMetrics
    ) -> [(item: TerminalInlineImageOverlayItem, frame: CGRect)] {
        let grouped = Dictionary(grouping: items, by: { $0.annotation.rowIndex })
        return grouped.keys.sorted().flatMap { rowIndex in
            var trailingX = bounds.width - 8
            return grouped[rowIndex, default: []].map { item in
                let size = thumbnailSize(for: item.thumbnail, rowHeight: metrics.cellHeight)
                let rowTop = metrics.viewHeight - (
                    metrics.yInset + CGFloat(item.annotation.rowIndex) * metrics.cellHeight
                )
                let frame = CGRect(
                    x: max(8, trailingX - size.width),
                    y: min(max(rowTop - size.height, 8), max(bounds.height - size.height - 8, 8)),
                    width: size.width,
                    height: size.height
                )
                trailingX = frame.minX - 6
                return (item, frame)
            }
        }
    }

    private func thumbnailSize(for thumbnail: TerminalInlineImageThumbnail, rowHeight: CGFloat) -> CGSize {
        let height = min(max(rowHeight * 3.5, 36), 72)
        let aspect = max(thumbnail.pixelSize.width / max(thumbnail.pixelSize.height, 1), 0.2)
        let width = min(max(height * aspect, 36), 128)
        return CGSize(width: width, height: height)
    }
}

@MainActor
private final class TerminalInlineImageThumbnailView: NSView {
    var openPreview: ((URL) -> Void)?
    private var url: URL?
    private let imageLayer = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.7).cgColor
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.45).cgColor
        imageLayer.contentsGravity = .resizeAspectFill
        layer?.addSublayer(imageLayer)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
    }

    func configure(item: TerminalInlineImageOverlayItem) {
        url = URL(fileURLWithPath: item.annotation.resolvedPath)
        imageLayer.contents = item.thumbnail.cgImage
        let label = String(
            localized: "terminal.inlineImageThumbnail.accessibilityLabel",
            defaultValue: "Image thumbnail"
        )
        let tooltip = String(
            localized: "terminal.inlineImageThumbnail.tooltip",
            defaultValue: "Preview image"
        )
        setAccessibilityLabel(label)
        toolTip = tooltip
    }

    override func mouseDown(with event: NSEvent) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return }
        openPreview?(url)
    }
}
