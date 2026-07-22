import CMUXMobileCore
import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

enum PaneMapTileMetrics {
    static let captionHeight: CGFloat = 38
    static let cornerRadius: CGFloat = 16
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
            terminalTheme.terminalBackgroundColor

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
                    PaneMapPaneNumberBadge(
                        paneID: item.pane.id,
                        paneNumber: item.paneNumber,
                        terminalTheme: terminalTheme
                    )
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
        .background(terminalTheme.terminalBackgroundColor)
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
        ZStack(alignment: .topLeading) {
            terminalTheme.terminalBackgroundColor
            if let preview {
                PaneMapTerminalCanvas(preview: preview, terminalTheme: terminalTheme)
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

            let lineHeightRatio: CGFloat = 1.82
            let widthCell = size.width / CGFloat(preview.columns)
            let heightCell = size.height / (CGFloat(preview.rows.count) * lineHeightRatio)
            let cellWidth = max(0.1, min(widthCell, heightCell))
            let lineHeight = cellWidth * lineHeightRatio
            let fontSize = max(0.5, cellWidth / 0.61)

            for (rowIndex, row) in preview.rows.enumerated() {
                drawBackgrounds(
                    row,
                    rowIndex: rowIndex,
                    cellWidth: cellWidth,
                    lineHeight: lineHeight,
                    context: &context
                )
                drawGlyphs(
                    row,
                    rowIndex: rowIndex,
                    cellWidth: cellWidth,
                    lineHeight: lineHeight,
                    fontSize: fontSize,
                    context: &context
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func drawBackgrounds(
        _ row: [MobileTerminalPaneMapPreview.Cell],
        rowIndex: Int,
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
                        x: CGFloat(startColumn) * cellWidth,
                        y: CGFloat(rowIndex) * lineHeight,
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
                    x: CGFloat(column) * cellWidth,
                    y: CGFloat(rowIndex) * lineHeight
                ),
                anchor: .topLeading
            )
            if style.isOverlined {
                let width = CGFloat(max(1, cell.columnSpan)) * cellWidth
                context.stroke(
                    Path(CGRect(
                        x: CGFloat(column) * cellWidth,
                        y: CGFloat(rowIndex) * lineHeight,
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

private struct PaneMapPaneNumberBadge: View {
    let paneID: String
    let paneNumber: Int
    let terminalTheme: TerminalTheme

    var body: some View {
        Text(paneNumber, format: .number)
            .font(.caption2.weight(.bold))
            .foregroundStyle(terminalTheme.terminalChromeForegroundColor)
            .frame(width: 26, height: 26)
            .mobileGlassCircle()
            .accessibilityIdentifier("MobilePaneMapPaneNumber-\(paneID)")
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
        .fixedSize(horizontal: true, vertical: true)
        .frame(maxWidth: 132)
        .mobileGlassPill()
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
