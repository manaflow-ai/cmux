import AppKit
import SwiftUI

@MainActor
func workspaceLayoutRenderAppKitTabChromeImage(
    scenario: WorkspaceLayoutTabChromeDebugScenario,
    scale: CGFloat = 2
) -> NSImage? {
    let view = WorkspaceLayoutNativeTabButtonView(frame: .zero)
    let renderTab = scenario.tab
    view.update(
        tab: renderTab,
        paneId: PaneID(),
        isSelected: scenario.isSelected,
        isPaneFocused: true,
        showsZoomIndicator: scenario.showsZoomIndicator,
        controlShortcutDigit: nil,
        showsControlShortcutHint: false,
        shortcutModifierSymbol: "⌃",
        appearance: scenario.appearance,
        contextMenuState: TabContextMenuState(
            isPinned: scenario.tab.isPinned,
            isUnread: scenario.tab.showsNotificationBadge,
            isBrowser: scenario.tab.kind == .browser,
            isTerminal: scenario.tab.kind == .terminal,
            hasCustomTitle: scenario.tab.hasCustomTitle,
            canCloseToLeft: false,
            canCloseToRight: false,
            canCloseOthers: false,
            canMoveToLeftPane: false,
            canMoveToRightPane: false,
            isZoomed: scenario.showsZoomIndicator,
            hasSplits: scenario.showsZoomIndicator,
            shortcuts: [:]
        ),
        onSelect: {},
        onClose: {},
        onZoomToggle: {},
        onContextAction: { _ in },
        onBeginTabDrag: {},
        onCancelTabDrag: {}
    )
    view.configureDebugInteractionState(
        isHovered: scenario.isHovered,
        isCloseHovered: scenario.isCloseHovered,
        isClosePressed: scenario.isClosePressed,
        isZoomHovered: scenario.isZoomHovered,
        isZoomPressed: scenario.isZoomPressed
    )
    let width = view.preferredWidth(
        minWidth: scenario.appearance.tabMinWidth,
        maxWidth: scenario.appearance.tabMaxWidth
    )
    view.frame = CGRect(x: 0, y: 0, width: width, height: TabBarMetrics.tabHeight)
    view.layoutSubtreeIfNeeded()
    return workspaceSplitSnapshotImage(
        for: view,
        scale: scale,
        backgroundColor: TabBarColors.nsColorPaneBackground(for: scenario.appearance)
    )
}

@MainActor
func workspaceLayoutRenderReferenceTabChromeImage(
    scenario: WorkspaceLayoutTabChromeDebugScenario,
    scale: CGFloat = 2
) -> NSImage? {
    let rootView = WorkspaceLayoutReferenceTabChromeView(
        tab: scenario.tab,
        isSelected: scenario.isSelected,
        isHovered: scenario.isHovered,
        isCloseHovered: scenario.isCloseHovered,
        isClosePressed: scenario.isClosePressed,
        showsZoomIndicator: scenario.showsZoomIndicator,
        isZoomHovered: scenario.isZoomHovered,
        isZoomPressed: scenario.isZoomPressed,
        appearance: scenario.appearance,
        fixedSpinnerPhase: scenario.tab.isLoading ? 0 : nil
    )
    let host = NSHostingView(rootView: rootView)
    let fittingWidth = ceil(host.fittingSize.width)
    host.frame = CGRect(x: 0, y: 0, width: fittingWidth, height: TabBarMetrics.tabHeight)
    host.layoutSubtreeIfNeeded()
    return workspaceSplitSnapshotImage(
        for: host,
        scale: scale,
        backgroundColor: TabBarColors.nsColorPaneBackground(for: scenario.appearance)
    )
}

func workspaceSplitAccessoryButtonTuning() -> (
    accessoryDX: CGFloat,
    accessoryDY: CGFloat,
    accessoryPointSizeDelta: CGFloat,
    closeGlyphDX: CGFloat,
    closeGlyphDY: CGFloat,
    closeCircleDX: CGFloat,
    closeCircleDY: CGFloat,
    closeCircleSizeDelta: CGFloat
) {
#if DEBUG
    let tuning = WorkspaceLayoutTabChromeDebugTuning.current
    return (
        accessoryDX: tuning.accessoryDX,
        accessoryDY: tuning.accessoryDY,
        accessoryPointSizeDelta: tuning.accessoryPointSizeDelta,
        closeGlyphDX: tuning.closeGlyphDX,
        closeGlyphDY: tuning.closeGlyphDY,
        closeCircleDX: tuning.closeCircleDX,
        closeCircleDY: tuning.closeCircleDY,
        closeCircleSizeDelta: tuning.closeCircleSizeDelta
    )
#else
    (
        accessoryDX: CGFloat(0),
        accessoryDY: WorkspaceLayoutTabChromeAccessoryMetrics.baseDY,
        accessoryPointSizeDelta: WorkspaceLayoutTabChromeAccessoryMetrics.basePointSizeDelta,
        closeGlyphDX: CGFloat(0),
        closeGlyphDY: CGFloat(0),
        closeCircleDX: CGFloat(0),
        closeCircleDY: WorkspaceLayoutTabChromeAccessoryMetrics.baseCloseCircleDY,
        closeCircleSizeDelta: CGFloat(0)
    )
#endif
}

func workspaceSplitAccessoryBackgroundColor(
    isHovered: Bool,
    isPressed: Bool,
    appearance: WorkspaceLayoutConfiguration.Appearance
) -> NSColor {
    if isPressed {
        return workspaceSplitPressedTabBackground(for: appearance)
    }
    if isHovered {
        return workspaceSplitHoveredTabBackground(for: appearance)
    }
    return .clear
}

func workspaceSplitDrawAccessoryButton(
    in rect: CGRect,
    symbolName: String,
    pointSize: CGFloat,
    isHovered: Bool,
    isPressed: Bool,
    appearance: WorkspaceLayoutConfiguration.Appearance
) {
    let tuning = workspaceSplitAccessoryButtonTuning()
    let backgroundColor = workspaceSplitAccessoryBackgroundColor(
        isHovered: isHovered,
        isPressed: isPressed,
        appearance: appearance
    )
    if backgroundColor.alphaComponent > 0 {
        let backgroundRect = CGRect(
            x: rect.minX + tuning.closeCircleDX - (tuning.closeCircleSizeDelta / 2),
            y: rect.minY + tuning.closeCircleDY - (tuning.closeCircleSizeDelta / 2),
            width: max(1, rect.width + tuning.closeCircleSizeDelta),
            height: max(1, rect.height + tuning.closeCircleSizeDelta)
        )
        backgroundColor.setFill()
        NSBezierPath(ovalIn: backgroundRect).fill()
    }
    let tint = (isHovered || isPressed)
        ? TabBarColors.nsColorActiveText(for: appearance)
        : TabBarColors.nsColorInactiveText(for: appearance)
    let glyphDX = tuning.accessoryDX + (symbolName == "xmark" ? tuning.closeGlyphDX : 0)
    let glyphDY = tuning.accessoryDY + (symbolName == "xmark" ? tuning.closeGlyphDY : 0)
    workspaceSplitDrawSymbol(
        named: symbolName,
        pointSize: pointSize + tuning.accessoryPointSizeDelta,
        weight: .semibold,
        color: tint,
        in: rect.offsetBy(dx: glyphDX, dy: glyphDY)
    )
}

final class WorkspaceLayoutAccessoryDebugPreviewView: NSView {
    var symbolName: String
    var pointSize: CGFloat
    var isHovered: Bool
    var isPressed: Bool
    var splitAppearance: WorkspaceLayoutConfiguration.Appearance

    init(
        frame frameRect: NSRect,
        symbolName: String,
        pointSize: CGFloat,
        isHovered: Bool,
        isPressed: Bool,
        appearance: WorkspaceLayoutConfiguration.Appearance
    ) {
        self.symbolName = symbolName
        self.pointSize = pointSize
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.splitAppearance = appearance
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        symbolName: String,
        pointSize: CGFloat,
        isHovered: Bool,
        isPressed: Bool,
        appearance: WorkspaceLayoutConfiguration.Appearance
    ) {
        self.symbolName = symbolName
        self.pointSize = pointSize
        self.isHovered = isHovered
        self.isPressed = isPressed
        self.splitAppearance = appearance
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let buttonRect = CGRect(
            x: floor((bounds.width - TabBarMetrics.closeButtonSize) / 2),
            y: floor((bounds.height - TabBarMetrics.closeButtonSize) / 2),
            width: TabBarMetrics.closeButtonSize,
            height: TabBarMetrics.closeButtonSize
        )
        workspaceSplitDrawAccessoryButton(
            in: buttonRect,
            symbolName: symbolName,
            pointSize: pointSize,
            isHovered: isHovered,
            isPressed: isPressed,
            appearance: splitAppearance
        )
    }
}

final class WorkspaceLayoutNativeTabButtonDebugPreviewHost: NSView {
    let button = WorkspaceLayoutNativeTabButtonView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        title: String,
        icon: String?,
        kind: WorkspaceLayoutTabKind,
        appearance: WorkspaceLayoutConfiguration.Appearance,
        isSelected: Bool,
        isHovered: Bool,
        isCloseHovered: Bool,
        isClosePressed: Bool
    ) {
        let tab = WorkspaceLayout.Tab.rendered(
            title: title,
            icon: icon,
            kind: kind
        )
        let contextMenuState = TabContextMenuState(
            isPinned: false,
            isUnread: false,
            isBrowser: kind == .browser,
            isTerminal: kind == .terminal,
            hasCustomTitle: false,
            canCloseToLeft: false,
            canCloseToRight: false,
            canCloseOthers: false,
            canMoveToLeftPane: false,
            canMoveToRightPane: false,
            isZoomed: false,
            hasSplits: false,
            shortcuts: [:]
        )
        button.update(
            tab: tab,
            paneId: PaneID(),
            isSelected: isSelected,
            isPaneFocused: true,
            showsZoomIndicator: false,
            controlShortcutDigit: nil,
            showsControlShortcutHint: false,
            shortcutModifierSymbol: "⌃",
            appearance: appearance,
            contextMenuState: contextMenuState,
            onSelect: {},
            onClose: {},
            onZoomToggle: {},
            onContextAction: { _ in },
            onBeginTabDrag: {},
            onCancelTabDrag: {}
        )
        button.configureDebugInteractionState(
            isHovered: isHovered,
            isCloseHovered: isCloseHovered,
            isClosePressed: isClosePressed,
            isZoomHovered: false,
            isZoomPressed: false
        )
        let width = button.preferredWidth(
            minWidth: appearance.tabMinWidth,
            maxWidth: appearance.tabMaxWidth
        )
        frame.size = CGSize(width: width, height: TabBarMetrics.tabHeight)
        button.frame = CGRect(x: 0, y: 0, width: width, height: TabBarMetrics.tabHeight)
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        CGSize(width: max(1, button.frame.width), height: TabBarMetrics.tabHeight)
    }
}

@MainActor
func workspaceLayoutTabChromeDebugDiff(
    appKitImage: NSImage,
    referenceImage: NSImage
) -> (image: NSImage, metrics: WorkspaceLayoutTabChromeDebugDiffMetrics)? {
    guard let appKitBuffer = workspaceLayoutRGBAImageBuffer(from: appKitImage),
          let referenceBuffer = workspaceLayoutRGBAImageBuffer(from: referenceImage) else {
        return nil
    }

    let width = max(appKitBuffer.width, referenceBuffer.width)
    let height = max(appKitBuffer.height, referenceBuffer.height)
    guard let resizedAppKit = workspaceLayoutResizeImageBuffer(appKitBuffer, width: width, height: height),
          let resizedReference = workspaceLayoutResizeImageBuffer(referenceBuffer, width: width, height: height) else {
        return nil
    }

    var diffBytes = [UInt8](repeating: 0, count: width * height * 4)
    var differingPixelCount = 0
    var maxChannelDelta = 0
    var totalChannelDelta = 0

    for pixelIndex in 0..<(width * height) {
        let base = pixelIndex * 4
        let rDelta = abs(Int(resizedAppKit.bytes[base]) - Int(resizedReference.bytes[base]))
        let gDelta = abs(Int(resizedAppKit.bytes[base + 1]) - Int(resizedReference.bytes[base + 1]))
        let bDelta = abs(Int(resizedAppKit.bytes[base + 2]) - Int(resizedReference.bytes[base + 2]))
        let aDelta = abs(Int(resizedAppKit.bytes[base + 3]) - Int(resizedReference.bytes[base + 3]))
        let pixelMax = max(rDelta, gDelta, bDelta, aDelta)
        if pixelMax > 0 {
            differingPixelCount += 1
        }
        maxChannelDelta = max(maxChannelDelta, pixelMax)
        totalChannelDelta += rDelta + gDelta + bDelta + aDelta

        diffBytes[base] = UInt8(clamping: rDelta)
        diffBytes[base + 1] = UInt8(clamping: gDelta)
        diffBytes[base + 2] = UInt8(clamping: bDelta)
        diffBytes[base + 3] = pixelMax == 0 ? 0 : 255
    }

    guard let diffImage = workspaceLayoutImageFromRGBABytes(
        diffBytes,
        width: width,
        height: height
    ) else {
        return nil
    }

    let totalPixels = width * height
    let meanAbsoluteChannelDelta = totalPixels == 0
        ? 0
        : Double(totalChannelDelta) / Double(totalPixels * 4)
    let metrics = WorkspaceLayoutTabChromeDebugDiffMetrics(
        width: width,
        height: height,
        differingPixelCount: differingPixelCount,
        totalPixelCount: totalPixels,
        maxChannelDelta: maxChannelDelta,
        meanAbsoluteChannelDelta: meanAbsoluteChannelDelta,
        matchingPixels: differingPixelCount == 0
    )
    return (diffImage, metrics)
}

@MainActor
func workspaceLayoutExportTabChromeDebugArtifacts(
    to directory: URL,
    scale: CGFloat = 2
) throws -> WorkspaceLayoutTabChromeDebugExportManifest {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

    var scenarioResults: [WorkspaceLayoutTabChromeDebugExportScenarioResult] = []
    for scenario in workspaceLayoutTabChromeDebugScenarios() {
        guard let appKitImage = workspaceLayoutRenderAppKitTabChromeImage(scenario: scenario, scale: scale) else {
            continue
        }

        let appKitName = "\(scenario.id)-appkit.png"
        try workspaceLayoutWritePNG(image: appKitImage, to: directory.appendingPathComponent(appKitName))
        scenarioResults.append(
            WorkspaceLayoutTabChromeDebugExportScenarioResult(
                id: scenario.id,
                title: scenario.title,
                appKitPNG: appKitName,
                scenario: workspaceLayoutTabChromeDebugScenarioSpec(from: scenario)
            )
        )
    }

    let formatter = ISO8601DateFormatter()
    let manifest = WorkspaceLayoutTabChromeDebugExportManifest(
        generatedAt: formatter.string(from: Date()),
        scenarioResults: scenarioResults
    )
    let manifestURL = directory.appendingPathComponent("manifest.json")
    let data = try JSONEncoder().encode(manifest)
    try data.write(to: manifestURL, options: .atomic)
    return manifest
}

func workspaceLayoutTabChromeDebugScenarioSpec(
    from scenario: WorkspaceLayoutTabChromeDebugScenario
) -> WorkspaceLayoutTabChromeDebugScenarioSpec {
    WorkspaceLayoutTabChromeDebugScenarioSpec(
        tab: WorkspaceLayoutTabChromeDebugTabSpec(
            id: scenario.tab.id.id,
            title: scenario.tab.title,
            hasCustomTitle: scenario.tab.hasCustomTitle,
            icon: scenario.tab.icon,
            iconImageDataBase64: scenario.tab.iconImageData?.base64EncodedString(),
            kind: scenario.tab.kind,
            isDirty: scenario.tab.isDirty,
            showsNotificationBadge: scenario.tab.showsNotificationBadge,
            isLoading: scenario.tab.isLoading,
            isPinned: scenario.tab.isPinned
        ),
        isSelected: scenario.isSelected,
        isHovered: scenario.isHovered,
        isCloseHovered: scenario.isCloseHovered,
        isClosePressed: scenario.isClosePressed,
        showsZoomIndicator: scenario.showsZoomIndicator,
        isZoomHovered: scenario.isZoomHovered,
        isZoomPressed: scenario.isZoomPressed,
        appearance: WorkspaceLayoutTabChromeDebugAppearanceSpec(
            tabBarHeight: Double(scenario.appearance.tabBarHeight),
            tabMinWidth: Double(scenario.appearance.tabMinWidth),
            tabMaxWidth: Double(scenario.appearance.tabMaxWidth),
            tabTitleFontSize: Double(scenario.appearance.tabTitleFontSize),
            tabSpacing: Double(scenario.appearance.tabSpacing),
            minimumPaneWidth: Double(scenario.appearance.minimumPaneWidth),
            minimumPaneHeight: Double(scenario.appearance.minimumPaneHeight),
            showSplitButtons: scenario.appearance.showSplitButtons,
            splitButtonsOnHover: scenario.appearance.splitButtonsOnHover,
            tabBarLeadingInset: Double(scenario.appearance.tabBarLeadingInset),
            splitButtonTooltips: WorkspaceLayoutTabChromeDebugSplitButtonTooltipsSpec(
                newTerminal: scenario.appearance.splitButtonTooltips.newTerminal,
                newBrowser: scenario.appearance.splitButtonTooltips.newBrowser,
                splitRight: scenario.appearance.splitButtonTooltips.splitRight,
                splitDown: scenario.appearance.splitButtonTooltips.splitDown
            ),
            animationDuration: scenario.appearance.animationDuration,
            enableAnimations: scenario.appearance.enableAnimations,
            chromeColors: WorkspaceLayoutTabChromeDebugChromeColorsSpec(
                backgroundHex: scenario.appearance.chromeColors.backgroundHex,
                borderHex: scenario.appearance.chromeColors.borderHex
            )
        )
    )
}
