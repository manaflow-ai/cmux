import AppKit
import CmuxTerminal
import CmuxTerminalCore
import GhosttyKit

@MainActor
final class TerminalOverlayLineView: NSVisualEffectView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        alphaValue = 0.92

        label.isEditable = false
        label.isSelectable = false
        label.drawsBackground = false
        label.isBezeled = false
        label.usesSingleLineMode = true
        label.lineBreakMode = .byTruncatingTail
        label.cell?.wraps = false
        label.textColor = .labelColor
        addSubview(label)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    func apply(
        _ overlay: TerminalOverlay,
        cellSize: CGSize,
        stripWidth: CGFloat
    ) -> CGSize {
        let cellWidth = cellSize.width > 0 ? cellSize.width : 8
        let cellHeight = cellSize.height > 0 ? cellSize.height : 18
        guard stripWidth > 0 else { return .zero }
        let horizontalInset = min(cellWidth, stripWidth / 4)
        let availableContentWidth = max(0, stripWidth - horizontalInset * 2)
        let contentWidth = min(
            availableContentWidth,
            CGFloat(overlay.maximumWidthColumns) * cellWidth
        )
        guard contentWidth > 0 else { return .zero }
        let contentOriginX: CGFloat
        switch overlay.horizontalAlignment {
        case .left:
            contentOriginX = horizontalInset
            label.alignment = .left
        case .center:
            contentOriginX = max(0, (stripWidth - contentWidth) / 2)
            label.alignment = .center
        case .right:
            contentOriginX = max(0, stripWidth - horizontalInset - contentWidth)
            label.alignment = .right
        }

        let displayText = overlay.text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        label.stringValue = displayText
        label.font = NSFont.monospacedSystemFont(
            ofSize: max(9, min(18, cellHeight * 0.65)),
            weight: .regular
        )
        label.maximumNumberOfLines = 1
        label.frame = CGRect(
            x: contentOriginX,
            y: 0,
            width: contentWidth,
            height: cellHeight
        )
        label.identifier = NSUserInterfaceItemIdentifier("terminal-overlay-\(overlay.id)")
        label.setAccessibilityIdentifier("terminal-overlay-\(overlay.id)")
        label.setAccessibilityLabel(displayText)
        return CGSize(width: stripWidth, height: cellHeight)
    }
}

private struct TerminalOverlayGridMetrics {
    let columns: Int
    let cellSize: CGSize
    let leftPadding: CGFloat
    let topPadding: CGFloat
}

private struct ScrollbackOverlayStackKey: Hashable {
    let row: Int
    let rowSpaceRevision: UInt64
}

private struct ScrollbackOverlayLinePlacement {
    let line: TerminalOverlayLineView
    let row: Int
    let rowSpaceRevision: UInt64
    let size: CGSize
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
              native.padding_left.isFinite,
              native.padding_top.isFinite else {
            return nil
        }
        return TerminalOverlayGridMetrics(
            columns: Int(native.columns),
            cellSize: CGSize(
                width: CGFloat(native.cell_width),
                height: CGFloat(native.cell_height)
            ),
            leftPadding: max(0, CGFloat(native.padding_left)),
            topPadding: max(0, CGFloat(native.padding_top))
        )
    }
}

@MainActor
extension GhosttySurfaceScrollView {
    func captureTerminalOverlayScrollbackAnchor(
        sticksToViewportTop: Bool
    ) -> TerminalOverlayAnchor? {
        guard let geometry = surfaceView.authoritativeScrollbarGeometry(),
              geometry.scrollbar.len > 0 else {
            return nil
        }
        return .scrollback(
            row: Int(clamping: geometry.scrollbar.offset),
            rowSpaceRevision: geometry.rowSpaceRevision,
            sticksToViewportTop: sticksToViewportTop
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
            terminalOverlayViews[overlay.id] = TerminalOverlayLineView(frame: .zero)
        }
        synchronizeTerminalOverlays()
    }

    func synchronizeTerminalOverlays() {
        guard !renderedTerminalOverlays.isEmpty else { return }

        let gridMetrics = surfaceView.terminalOverlayGridMetrics()
        let cellSize = gridMetrics?.cellSize ?? surfaceView.cellSize
        guard cellSize.width > 0, cellSize.height > 0 else { return }
        let fallbackColumns = max(1, Int(sessionContentFrame.width / cellSize.width))
        let columns = gridMetrics?.columns ?? fallbackColumns
        let leftPadding = gridMetrics?.leftPadding ?? 0
        let topPadding = gridMetrics?.topPadding ?? 0
        var viewportLines: [TerminalOverlayLineView] = []
        var scrollbackLines: [ScrollbackOverlayLinePlacement] = []
        let scrollbackGeometry = renderedTerminalOverlays.contains(where: {
            if case .scrollback = $0.anchor { return true }
            return false
        }) ? surfaceView.authoritativeScrollbarGeometry() : nil

        if let scrollbackGeometry,
           renderedTerminalOverlays.contains(where: { overlay in
               guard case .scrollback(_, let revision, _) = overlay.anchor else { return false }
               return revision != scrollbackGeometry.rowSpaceRevision
           }),
           let terminalSurface = surfaceView.terminalSurface,
           !terminalSurface.removeInvalidatedTerminalOverlayAnchors(
               currentRowSpaceRevision: scrollbackGeometry.rowSpaceRevision
           ).isEmpty {
            return
        }

        for overlay in renderedTerminalOverlays {
            guard let line = terminalOverlayViews[overlay.id] else { continue }
            let containerWidth: CGFloat
            switch overlay.anchor {
            case .viewportTop:
                containerWidth = sessionContentFrame.width
            case .scrollback:
                containerWidth = documentView.bounds.width
            }
            let stripWidth = min(
                max(0, containerWidth - leftPadding),
                CGFloat(columns) * cellSize.width
            )
            let lineSize = line.apply(
                overlay,
                cellSize: cellSize,
                stripWidth: stripWidth
            )
            guard lineSize.width > 0, lineSize.height > 0 else {
                line.isHidden = true
                continue
            }

            switch overlay.anchor {
            case .viewportTop:
                attachTerminalOverlayLineToViewport(line)
                viewportLines.append(line)

            case .scrollback(let row, let rowSpaceRevision, let sticksToViewportTop):
                guard let geometry = scrollbackGeometry,
                      geometry.scrollbar.len > 0 else {
                    line.isHidden = true
                    continue
                }
                let placement = TerminalOverlayGeometry.scrollbackPlacement(
                    row: row,
                    capturedRowSpaceRevision: rowSpaceRevision,
                    sticksToViewportTop: sticksToViewportTop,
                    viewportTopRow: Int(clamping: geometry.scrollbar.offset),
                    visibleRows: Int(clamping: geometry.scrollbar.len),
                    totalRows: Int(clamping: geometry.scrollbar.total),
                    currentRowSpaceRevision: geometry.rowSpaceRevision
                )
                switch placement {
                case .invalidated, .hidden:
                    line.isHidden = true

                case .viewportTop:
                    attachTerminalOverlayLineToViewport(line)
                    viewportLines.append(line)

                case .document:
                    if line.superview !== documentView {
                        line.removeFromSuperview()
                        documentView.addSubview(line, positioned: .above, relativeTo: surfaceView)
                    }
                    scrollbackLines.append(ScrollbackOverlayLinePlacement(
                        line: line,
                        row: row,
                        rowSpaceRevision: rowSpaceRevision,
                        size: lineSize
                    ))
                }
            }
        }

        for (stackIndex, line) in viewportLines.enumerated() {
            guard let frame = TerminalOverlayGeometry.gridStripFrame(
                containerFrame: sessionContentFrame,
                columns: columns,
                cellSize: cellSize,
                leftPadding: leftPadding,
                topPadding: topPadding,
                stackIndex: stackIndex
            ) else {
                line.isHidden = true
                continue
            }
            line.frame = frame
            line.isHidden = false
        }

        var scrollbackStackIndexes: [ScrollbackOverlayStackKey: Int] = [:]
        for placement in scrollbackLines {
            let stackKey = ScrollbackOverlayStackKey(
                row: placement.row,
                rowSpaceRevision: placement.rowSpaceRevision
            )
            let stackIndex = scrollbackStackIndexes[stackKey, default: 0]
            guard let originY = TerminalOverlayGeometry.scrollbackOverlayOriginY(
                documentHeight: documentHeight(),
                row: placement.row,
                totalRows: Int(clamping: scrollbackGeometry?.scrollbar.total ?? 0),
                cellHeight: cellSize.height,
                topPadding: topPadding,
                overlayHeight: placement.size.height
            ) else {
                placement.line.isHidden = true
                continue
            }
            placement.line.frame = CGRect(
                x: leftPadding,
                y: originY - CGFloat(stackIndex) * cellSize.height,
                width: placement.size.width,
                height: placement.size.height
            )
            placement.line.isHidden = false
            scrollbackStackIndexes[stackKey] = stackIndex + 1
        }
    }

    private func attachTerminalOverlayLineToViewport(_ line: TerminalOverlayLineView) {
        if line.superview !== self {
            line.removeFromSuperview()
            addSubview(line, positioned: .above, relativeTo: scrollView)
        }
    }
}
