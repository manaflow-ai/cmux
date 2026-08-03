import AppKit
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit

@MainActor
final class TerminalOverlayCardView: NSVisualEffectView {
    private enum Metrics {
        static let horizontalPadding: CGFloat = 12
        static let verticalPadding: CGFloat = 9
        static let minimumContentWidth: CGFloat = 96
    }

    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        alphaValue = 0.96
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true

        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.usesSingleLineMode = false
        label.lineBreakMode = .byWordWrapping
        label.cell?.wraps = true
        label.textColor = .labelColor
        addSubview(label)
        updateBorderColor()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    func apply(
        _ overlay: TerminalOverlay,
        cellSize: CGSize,
        availableWidth: CGFloat
    ) -> CGSize {
        let cellWidth = cellSize.width > 0 ? cellSize.width : 8
        let cellHeight = cellSize.height > 0 ? cellSize.height : 18
        let fontSize = max(10, min(20, cellHeight * 0.72))
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .medium)
        let maximumCardWidth = min(
            max(0, availableWidth - 16),
            CGFloat(overlay.maximumWidthColumns) * cellWidth + Metrics.horizontalPadding * 2
        )
        guard maximumCardWidth > Metrics.horizontalPadding * 2 else { return .zero }

        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        let naturalLineWidth = overlay.text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                ceil((String(line) as NSString).size(withAttributes: attributes).width)
            }
            .max() ?? Metrics.minimumContentWidth
        // `NSTextFieldCell` keeps a small horizontal text inset even for a
        // borderless label. Reserve one terminal cell so the final word does
        // not wrap into a clipped second line when the measured text otherwise
        // fits exactly.
        let contentWidth = min(
            maximumCardWidth - Metrics.horizontalPadding * 2,
            max(Metrics.minimumContentWidth, naturalLineWidth + cellWidth)
        )
        let measuredTextWidth = max(1, contentWidth - cellWidth)
        let maximumContentHeight = CGFloat(overlay.maximumHeightRows) * cellHeight
        let measured = (overlay.text as NSString).boundingRect(
            with: CGSize(width: measuredTextWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attributes
        )
        let contentHeight = min(maximumContentHeight, max(cellHeight, ceil(measured.height)))
        let size = CGSize(
            width: contentWidth + Metrics.horizontalPadding * 2,
            height: contentHeight + Metrics.verticalPadding * 2
        )

        label.stringValue = overlay.text
        label.font = font
        label.maximumNumberOfLines = overlay.maximumHeightRows
        label.frame = CGRect(
            x: Metrics.horizontalPadding,
            y: Metrics.verticalPadding,
            width: contentWidth,
            height: contentHeight
        )
        label.identifier = NSUserInterfaceItemIdentifier("terminal-overlay-\(overlay.id)")
        label.setAccessibilityIdentifier("terminal-overlay-\(overlay.id)")
        label.setAccessibilityLabel(overlay.text)
        return size
    }

    private func updateBorderColor() {
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.65).cgColor
    }
}

private struct TerminalOverlayGridMetrics {
    let cellSize: CGSize
    let topPadding: CGFloat
}

private struct ScrollbackOverlayStackKey: Hashable {
    let row: Int
    let rowSpaceRevision: UInt64
    let alignment: TerminalOverlayHorizontalAlignment
}

@MainActor
extension GhosttyNSView {
    fileprivate func terminalOverlayGridMetrics() -> TerminalOverlayGridMetrics? {
        guard let surface = terminalSurface?.liveSurfaceForGhosttyAccess(
            reason: "terminalOverlay.gridMetrics"
        ) else { return nil }
        var native = ghostty_surface_grid_metrics_s()
        guard ghostty_surface_grid_metrics(surface, &native),
              native.cell_width.isFinite,
              native.cell_width > 0,
              native.cell_height.isFinite,
              native.cell_height > 0,
              native.padding_top.isFinite else {
            return nil
        }
        return TerminalOverlayGridMetrics(
            cellSize: CGSize(
                width: CGFloat(native.cell_width),
                height: CGFloat(native.cell_height)
            ),
            topPadding: max(0, CGFloat(native.padding_top))
        )
    }
}

@MainActor
extension GhosttySurfaceScrollView {
    private enum OverlayMetrics {
        static let edgeMargin: CGFloat = 8
        static let stackSpacing: CGFloat = 6
    }

    func captureTerminalOverlayScrollbackAnchor() -> TerminalOverlayAnchor? {
        guard let geometry = surfaceView.authoritativeScrollbarGeometry(),
              geometry.scrollbar.len > 0 else {
            return nil
        }
        return .scrollback(
            row: Int(clamping: geometry.scrollbar.offset),
            rowSpaceRevision: geometry.rowSpaceRevision
        )
    }

    func setTerminalOverlays(_ overlays: [TerminalOverlay]) {
        renderedTerminalOverlays = overlays
        let validIDs = Set(overlays.map(\.id))
        let removedIDs = terminalOverlayViews.keys.filter { !validIDs.contains($0) }
        for id in removedIDs {
            terminalOverlayViews[id]?.removeFromSuperview()
            terminalOverlayViews.removeValue(forKey: id)
        }
        for overlay in overlays where terminalOverlayViews[overlay.id] == nil {
            terminalOverlayViews[overlay.id] = TerminalOverlayCardView(frame: .zero)
        }
        synchronizeTerminalOverlays()
    }

    func synchronizeTerminalOverlays() {
        guard !renderedTerminalOverlays.isEmpty else { return }

        let gridMetrics = surfaceView.terminalOverlayGridMetrics()
        let cellSize = gridMetrics?.cellSize ?? surfaceView.cellSize
        var viewportStackOffsets: [TerminalOverlayHorizontalAlignment: CGFloat] = [:]
        var scrollbackStackOffsets: [ScrollbackOverlayStackKey: CGFloat] = [:]
        let scrollbackGeometry = renderedTerminalOverlays.contains(where: {
            if case .scrollback = $0.anchor { return true }
            return false
        }) ? surfaceView.authoritativeScrollbarGeometry() : nil
        let topPadding = gridMetrics?.topPadding ?? 0

        for overlay in renderedTerminalOverlays {
            guard let card = terminalOverlayViews[overlay.id] else { continue }
            let availableWidth: CGFloat
            switch overlay.anchor {
            case .viewportTop:
                availableWidth = sessionContentFrame.width
            case .scrollback:
                availableWidth = documentView.bounds.width
            }
            let cardSize = card.apply(
                overlay,
                cellSize: cellSize,
                availableWidth: availableWidth
            )
            guard cardSize.width > 0, cardSize.height > 0 else {
                card.isHidden = true
                continue
            }

            switch overlay.anchor {
            case .viewportTop:
                if card.superview !== self {
                    card.removeFromSuperview()
                    addSubview(card, positioned: .above, relativeTo: scrollView)
                }
                let stackOffset = viewportStackOffsets[overlay.horizontalAlignment, default: 0]
                let localX = TerminalOverlayGeometry.horizontalOrigin(
                    containerWidth: sessionContentFrame.width,
                    overlayWidth: cardSize.width,
                    alignment: overlay.horizontalAlignment,
                    margin: OverlayMetrics.edgeMargin
                )
                let originY = sessionContentFrame.maxY
                    - OverlayMetrics.edgeMargin
                    - stackOffset
                    - cardSize.height
                card.frame = CGRect(
                    x: sessionContentFrame.minX + localX,
                    y: originY,
                    width: cardSize.width,
                    height: cardSize.height
                )
                card.isHidden = originY < sessionContentFrame.minY
                viewportStackOffsets[overlay.horizontalAlignment] = stackOffset
                    + cardSize.height
                    + OverlayMetrics.stackSpacing

            case .scrollback(let row, let rowSpaceRevision):
                if card.superview !== documentView {
                    card.removeFromSuperview()
                    documentView.addSubview(card, positioned: .above, relativeTo: surfaceView)
                }
                guard let geometry = scrollbackGeometry,
                      geometry.rowSpaceRevision == rowSpaceRevision,
                      let originY = TerminalOverlayGeometry.scrollbackOverlayOriginY(
                          documentHeight: documentHeight(),
                          row: row,
                          totalRows: Int(clamping: geometry.scrollbar.total),
                          cellHeight: cellSize.height,
                          topPadding: topPadding,
                          overlayHeight: cardSize.height
                      ) else {
                    card.isHidden = true
                    continue
                }
                let stackKey = ScrollbackOverlayStackKey(
                    row: row,
                    rowSpaceRevision: rowSpaceRevision,
                    alignment: overlay.horizontalAlignment
                )
                let stackOffset = scrollbackStackOffsets[stackKey, default: 0]
                let originX = TerminalOverlayGeometry.horizontalOrigin(
                    containerWidth: documentView.bounds.width,
                    overlayWidth: cardSize.width,
                    alignment: overlay.horizontalAlignment,
                    margin: OverlayMetrics.edgeMargin
                )
                card.frame = CGRect(
                    x: originX,
                    y: originY - stackOffset,
                    width: cardSize.width,
                    height: cardSize.height
                )
                card.isHidden = false
                scrollbackStackOffsets[stackKey] = stackOffset
                    + cardSize.height
                    + OverlayMetrics.stackSpacing
            }
        }
    }
}
