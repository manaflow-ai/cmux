import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

enum PaneMapTileMetrics {
    static let captionHeight: CGFloat = 38
    static let cornerRadius: CGFloat = 16
}

struct PaneMapTerminalCanvasLayout: Equatable {
    static let lineHeightRatio: CGFloat = 1.82
    static let glyphWidthRatio: CGFloat = 0.61

    let contentRect: CGRect
    let visibleRowRange: Range<Int>
    let drawOrigin: CGPoint
    let cellWidth: CGFloat
    let lineHeight: CGFloat
    let fontSize: CGFloat

    init(
        size: CGSize,
        columns: Int,
        rowCount: Int,
        inset: CGFloat
    ) {
        let safeSize = CGSize(
            width: max(0, size.width),
            height: max(0, size.height)
        )
        let safeInset = max(0, inset)
        contentRect = CGRect(
            x: safeInset,
            y: safeInset,
            width: max(0, safeSize.width - (safeInset * 2)),
            height: max(0, safeSize.height - (safeInset * 2))
        )

        guard columns > 0, rowCount > 0, contentRect.width > 0 else {
            visibleRowRange = 0..<0
            drawOrigin = contentRect.origin
            cellWidth = 0
            lineHeight = 0
            fontSize = 0
            return
        }

        cellWidth = contentRect.width / CGFloat(columns)
        lineHeight = cellWidth * Self.lineHeightRatio
        fontSize = cellWidth / Self.glyphWidthRatio

        let rowsThatFit = max(
            1,
            Int((contentRect.height / max(lineHeight, 0.1)).rounded(.down))
        )
        let visibleRowCount = min(rowCount, rowsThatFit)
        let isCropped = visibleRowCount < rowCount
        let firstVisibleRow = isCropped ? rowCount - visibleRowCount : 0
        visibleRowRange = firstVisibleRow..<(firstVisibleRow + visibleRowCount)
        drawOrigin = CGPoint(
            x: contentRect.minX,
            y: isCropped
                ? contentRect.maxY - (CGFloat(visibleRowCount) * lineHeight)
                : contentRect.minY
        )
    }

    var lastRowMaxY: CGFloat {
        drawOrigin.y + (CGFloat(visibleRowRange.count) * lineHeight)
    }
}

enum PaneMapTabStripMetrics {
    static let tabWidth: CGFloat = 28
    static let spacing: CGFloat = 2
    static let padding: CGFloat = 3
    static let maximumWidth: CGFloat = 132

    static func width(tabCount: Int) -> CGFloat {
        guard tabCount > 0 else { return 0 }
        let contentWidth =
            (CGFloat(tabCount) * tabWidth)
            + (CGFloat(max(0, tabCount - 1)) * spacing)
            + (padding * 2)
        return min(maximumWidth, contentWidth)
    }
}

/// One floating Safari-style pane card rendered from immutable snapshots.
struct PaneMapTileView: View {
    let item: PaneMapCollectionItem
    let terminalTheme: TerminalTheme
    let selectPreviewSurface: (String) -> Void
    let jumpToTerminal: (String) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PaneMapPreviewCard(
                item: item,
                terminalTheme: terminalTheme,
                selectPreviewSurface: selectPreviewSurface,
                jumpToTerminal: jumpToTerminal
            )
            PaneMapTileCaption(item: item, terminalTheme: terminalTheme)
                .frame(height: PaneMapTileMetrics.captionHeight)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(paneAccessibilityLabel)
        .accessibilityValue(
            item.isFocusedOnMac
                ? L10n.string("mobile.paneMap.focusedOnMac", defaultValue: "Focused on Mac")
                : ""
        )
        .accessibilityIdentifier("MobilePaneMapPane-\(item.pane.id)")
    }

    private var paneAccessibilityLabel: String {
        String.localizedStringWithFormat(
            L10n.string(
                "mobile.paneMap.panePosition",
                defaultValue: "Pane %d of %d"
            ),
            item.paneNumber,
            item.paneCount
        )
    }
}

private struct PaneMapPreviewCard: View {
    let item: PaneMapCollectionItem
    let terminalTheme: TerminalTheme
    let selectPreviewSurface: (String) -> Void
    let jumpToTerminal: (String) -> Void

    private var selectedSurface: MobilePaneSurface? { item.selectedSurface }
    private var isPhoneSelected: Bool {
        selectedSurface?.id == item.phoneSelectedSurfaceID
    }

    var body: some View {
        let shape = RoundedRectangle(
            cornerRadius: PaneMapTileMetrics.cornerRadius,
            style: .continuous
        )

        ZStack {
            previewTerminalTheme.terminalBackgroundColor

            if let selectedSurface {
                PaneMapSurfacePreview(
                    surface: selectedSurface,
                    preview: item.preview,
                    isLoadingPreview: item.isLoadingPreview,
                    terminalTheme: terminalTheme,
                    jumpToTerminal: jumpToTerminal
                )
            }

            VStack {
                HStack(alignment: .top) {
                    Spacer(minLength: 0)
                    if item.isFocusedOnMac {
                        PaneMapMacFocusBadge(terminalTheme: terminalTheme)
                    }
                }
                Spacer(minLength: 0)
                if item.pane.surfaces.count > 1 {
                    PaneMapTabSwitcher(
                        pane: item.pane,
                        selectedSurfaceID: item.selectedSurfaceID,
                        terminalTheme: terminalTheme,
                        selectPreviewSurface: selectPreviewSurface
                    )
                }
            }
            .padding(8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(previewTerminalTheme.terminalBackgroundColor)
        .overlay {
            shape.stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .overlay {
            if isPhoneSelected {
                shape.stroke(Color.accentColor, lineWidth: 2.5)
            }
        }
        .clipShape(shape)
        .shadow(color: .black.opacity(0.28), radius: 9, y: 5)
    }

    private var previewTerminalTheme: TerminalTheme {
        item.preview?.resolvedTerminalTheme(fallback: terminalTheme) ?? terminalTheme
    }
}

private struct PaneMapSurfacePreview: View {
    let surface: MobilePaneSurface
    let preview: MobileTerminalPaneMapPreview?
    let isLoadingPreview: Bool
    let terminalTheme: TerminalTheme
    let jumpToTerminal: (String) -> Void

    var body: some View {
        ZStack {
            if surface.type.isTerminal {
                Button {
                    jumpToTerminal(surface.id)
                } label: {
                    PaneMapTerminalPreview(
                        preview: preview,
                        isLoadingPreview: isLoadingPreview,
                        terminalTheme: terminalTheme
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(surfaceAccessibilityLabel)
                .accessibilityIdentifier("MobilePaneMapTile-\(surface.id)")
            } else {
                PaneMapUnavailableSurfacePreview(
                    surface: surface,
                    terminalTheme: terminalTheme
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var surfaceAccessibilityLabel: String {
        String.localizedStringWithFormat(
            L10n.string(
                "mobile.paneMap.openNamedTerminal",
                defaultValue: "Open terminal: %@"
            ),
            surface.title
        )
    }
}

private struct PaneMapTerminalPreview: View {
    let preview: MobileTerminalPaneMapPreview?
    let isLoadingPreview: Bool
    let terminalTheme: TerminalTheme

    var body: some View {
        let resolvedTerminalTheme =
            preview?.resolvedTerminalTheme(fallback: terminalTheme) ?? terminalTheme

        ZStack(alignment: .topLeading) {
            resolvedTerminalTheme.terminalBackgroundColor
            if let preview {
                PaneMapTerminalCanvas(
                    preview: preview,
                    terminalTheme: resolvedTerminalTheme
                )
            } else if isLoadingPreview {
                ProgressView()
                    .controlSize(.mini)
                    .tint(terminalTheme.terminalChromeForegroundColor.opacity(0.55))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
    }
}

private struct PaneMapTerminalCanvas: View {
    let preview: MobileTerminalPaneMapPreview
    let terminalTheme: TerminalTheme

    var body: some View {
        Canvas(opaque: true, colorMode: .nonLinear, rendersAsynchronously: true) { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(terminalTheme.terminalBackgroundColor)
            )
            guard preview.columns > 0, !preview.rows.isEmpty else { return }

            let layout = PaneMapTerminalCanvasLayout(
                size: size,
                columns: preview.columns,
                rowCount: preview.rows.count,
                inset: 6
            )
            guard !layout.visibleRowRange.isEmpty else { return }
            context.clip(to: Path(layout.contentRect))

            for (visibleRowIndex, sourceRowIndex) in layout.visibleRowRange.enumerated() {
                let row = preview.rows[sourceRowIndex]
                drawBackgrounds(
                    row,
                    rowIndex: visibleRowIndex,
                    origin: layout.drawOrigin,
                    cellWidth: layout.cellWidth,
                    lineHeight: layout.lineHeight,
                    context: &context
                )
                drawGlyphs(
                    row,
                    rowIndex: visibleRowIndex,
                    origin: layout.drawOrigin,
                    cellWidth: layout.cellWidth,
                    lineHeight: layout.lineHeight,
                    fontSize: layout.fontSize,
                    context: &context
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func drawBackgrounds(
        _ row: [MobileTerminalPaneMapPreview.Cell],
        rowIndex: Int,
        origin: CGPoint,
        cellWidth: CGFloat,
        lineHeight: CGFloat,
        context: inout GraphicsContext
    ) {
        var startColumn = 0
        while startColumn < row.count {
            let styleID = row[startColumn].styleID
            var endColumn = startColumn + 1
            while endColumn < row.count, row[endColumn].styleID == styleID {
                endColumn += 1
            }
            if let background = resolvedStyle(styleID).background {
                context.fill(
                    Path(CGRect(
                        x: origin.x + (CGFloat(startColumn) * cellWidth),
                        y: origin.y + (CGFloat(rowIndex) * lineHeight),
                        width: CGFloat(endColumn - startColumn) * cellWidth,
                        height: lineHeight
                    )),
                    with: .color(background)
                )
            }
            startColumn = endColumn
        }
    }

    private func drawGlyphs(
        _ row: [MobileTerminalPaneMapPreview.Cell],
        rowIndex: Int,
        origin: CGPoint,
        cellWidth: CGFloat,
        lineHeight: CGFloat,
        fontSize: CGFloat,
        context: inout GraphicsContext
    ) {
        for (column, cell) in row.enumerated()
            where cell.columnSpan > 0 && cell.text != " " && !cell.text.isEmpty {
            let style = resolvedStyle(cell.styleID)
            guard !style.isInvisible else { continue }
            var text = Text(cell.text)
                .font(.system(
                    size: fontSize,
                    weight: style.isBold ? .bold : .regular,
                    design: .monospaced
                ))
                .foregroundStyle(style.foreground.opacity(style.isFaint ? 0.56 : 1))
            if style.isItalic { text = text.italic() }
            if style.isUnderlined { text = text.underline() }
            if style.isStruckThrough { text = text.strikethrough() }
            context.draw(
                text,
                at: CGPoint(
                    x: origin.x + (CGFloat(column) * cellWidth),
                    y: origin.y + (CGFloat(rowIndex) * lineHeight)
                ),
                anchor: .topLeading
            )
            if style.isOverlined {
                let width = CGFloat(max(1, cell.columnSpan)) * cellWidth
                context.stroke(
                    Path(CGRect(
                        x: origin.x + (CGFloat(column) * cellWidth),
                        y: origin.y + (CGFloat(rowIndex) * lineHeight),
                        width: width,
                        height: 0.5
                    )),
                    with: .color(style.foreground),
                    lineWidth: max(0.35, fontSize * 0.06)
                )
            }
        }
    }

    private func resolvedStyle(_ styleID: Int) -> PaneMapResolvedTerminalStyle {
        let style = preview.stylesByID[styleID] ?? .default
        let defaultForeground = terminalTheme.terminalForegroundColor
        let defaultBackground = terminalTheme.terminalBackgroundColor
        let explicitForeground = style.foreground.map(Color.init(terminalHex:))
        let explicitBackground = style.background.map(Color.init(terminalHex:))
        let foreground: Color
        let background: Color?
        if style.inverse {
            foreground = explicitBackground ?? defaultBackground
            background = explicitForeground ?? defaultForeground
        } else {
            foreground = explicitForeground ?? defaultForeground
            background = explicitBackground
        }
        return PaneMapResolvedTerminalStyle(
            foreground: foreground,
            background: background,
            isBold: style.bold,
            isFaint: style.faint,
            isItalic: style.italic,
            isUnderlined: style.underline,
            isInvisible: style.invisible,
            isStruckThrough: style.strikethrough,
            isOverlined: style.overline
        )
    }
}

private struct PaneMapResolvedTerminalStyle {
    let foreground: Color
    let background: Color?
    let isBold: Bool
    let isFaint: Bool
    let isItalic: Bool
    let isUnderlined: Bool
    let isInvisible: Bool
    let isStruckThrough: Bool
    let isOverlined: Bool
}

private struct PaneMapUnavailableSurfacePreview: View {
    let surface: MobilePaneSurface
    let terminalTheme: TerminalTheme

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: surface.type.paneMapSystemImage)
                .font(.title2.weight(.medium))
            Text(
                L10n.string(
                    "mobile.paneMap.unavailableOnPhone",
                    defaultValue: "Unavailable on iPhone"
                )
            )
            .font(.caption2.weight(.medium))
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor.opacity(0.72))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(surface.title)
    }
}

private struct PaneMapMacFocusBadge: View {
    let terminalTheme: TerminalTheme

    var body: some View {
        Image(systemName: "macwindow")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
            .frame(width: 28, height: 26)
            .mobileGlassPill()
            .accessibilityLabel(
                L10n.string("mobile.paneMap.focusedOnMac", defaultValue: "Focused on Mac")
            )
    }
}

private struct PaneMapTabSwitcher: View {
    let pane: MobilePaneNode
    let selectedSurfaceID: String?
    let terminalTheme: TerminalTheme
    let selectPreviewSurface: (String) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(pane.surfaces, id: \.id) { surface in
                    let isSelected = surface.id == selectedSurfaceID
                    Button {
                        selectPreviewSurface(surface.id)
                    } label: {
                        Image(systemName: surface.type.paneMapSystemImage)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(
                                isSelected
                                    ? terminalTheme.terminalBackgroundColor
                                    : terminalTheme.terminalChromeForegroundColor.opacity(0.82)
                            )
                            .frame(width: 28, height: 28)
                            .background(
                                isSelected
                                    ? terminalTheme.terminalChromeForegroundColor.opacity(0.9)
                                    : .clear,
                                in: Circle()
                            )
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(surface.title)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .accessibilityIdentifier("MobilePaneMapTab-\(surface.id)")
                }
            }
            .padding(3)
        }
        .scrollIndicators(.hidden)
        .frame(
            width: PaneMapTabStripMetrics.width(tabCount: pane.surfaces.count),
            height: 34
        )
        .mobileGlassPill()
        .accessibilityIdentifier("MobilePaneMapTabStrip-\(pane.id)")
    }
}

private struct PaneMapTileCaption: View {
    let item: PaneMapCollectionItem
    let terminalTheme: TerminalTheme

    var body: some View {
        HStack(spacing: 6) {
            if let surface = item.selectedSurface {
                Image(systemName: surface.type.paneMapSystemImage)
                    .font(.caption2.weight(.semibold))
                Text(surface.title)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("MobilePaneMapCaption-\(surface.id)")
            }
            Spacer(minLength: 0)
            if let agentStateKind = item.agentStateKind {
                Circle()
                    .fill(agentStateKind == .working ? Color.green : Color.orange)
                    .frame(width: 7, height: 7)
                    .accessibilityLabel(statusAccessibilityValue(agentStateKind))
            }
        }
        .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private func statusAccessibilityValue(_ kind: ChatAgentStateKind) -> String {
        switch kind {
        case .working:
            return L10n.string("mobile.agent.status.working", defaultValue: "Agent working")
        case .needsInput:
            return L10n.string("mobile.agent.status.needsInput", defaultValue: "Agent needs input")
        }
    }
}

private extension MobilePaneSurfaceType {
    var paneMapSystemImage: String {
        switch self {
        case .terminal:
            return "terminal"
        case .browser:
            return "globe"
        case .markdown:
            return "doc.text"
        case .agentSession:
            return "sparkles"
        case .workspaceTodo:
            return "checklist"
        case .filepreview:
            return "doc"
        case .project:
            return "folder"
        case .rightSidebarTool, .customSidebar, .extensionBrowser, .cloudVMLoading, .other:
            return "rectangle"
        }
    }
}

private extension Color {
    init(terminalHex: String) {
        guard let rgb = TerminalTheme.rgbComponents(terminalHex) else {
            self = .primary
            return
        }
        self.init(
            red: Double(rgb.red) / 255,
            green: Double(rgb.green) / 255,
            blue: Double(rgb.blue) / 255
        )
    }
}
