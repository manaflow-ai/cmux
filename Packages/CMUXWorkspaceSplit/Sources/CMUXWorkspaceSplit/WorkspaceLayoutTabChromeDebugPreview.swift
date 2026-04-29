import AppKit
import SwiftUI

final class ClosureMenuTarget: NSObject {
    let handler: () -> Void

    init(handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func invoke(_ sender: Any?) {
        handler()
    }
}

struct WorkspaceLayoutTabChromeDebugScenario: Identifiable {
    let id: String
    let title: String
    let tab: WorkspaceLayout.Tab
    let isSelected: Bool
    let isHovered: Bool
    let isCloseHovered: Bool
    let isClosePressed: Bool
    let showsZoomIndicator: Bool
    let isZoomHovered: Bool
    let isZoomPressed: Bool
    let appearance: WorkspaceLayoutConfiguration.Appearance
}

struct WorkspaceLayoutTabChromeDebugDiffMetrics: Codable, Hashable {
    let width: Int
    let height: Int
    let differingPixelCount: Int
    let totalPixelCount: Int
    let maxChannelDelta: Int
    let meanAbsoluteChannelDelta: Double
    let matchingPixels: Bool
}

struct WorkspaceLayoutTabChromeDebugExportScenarioResult: Codable {
    let id: String
    let title: String
    let appKitPNG: String
    let scenario: WorkspaceLayoutTabChromeDebugScenarioSpec
}

struct WorkspaceLayoutTabChromeDebugExportManifest: Codable {
    let generatedAt: String
    let scenarioResults: [WorkspaceLayoutTabChromeDebugExportScenarioResult]
}

struct WorkspaceLayoutTabChromeDebugScenarioSpec: Codable {
    let tab: WorkspaceLayoutTabChromeDebugTabSpec
    let isSelected: Bool
    let isHovered: Bool
    let isCloseHovered: Bool
    let isClosePressed: Bool
    let showsZoomIndicator: Bool
    let isZoomHovered: Bool
    let isZoomPressed: Bool
    let appearance: WorkspaceLayoutTabChromeDebugAppearanceSpec
}

struct WorkspaceLayoutTabChromeDebugTabSpec: Codable {
    let id: UUID
    let title: String
    let hasCustomTitle: Bool
    let icon: String?
    let iconImageDataBase64: String?
    let kind: WorkspaceLayoutTabKind?
    let isDirty: Bool
    let showsNotificationBadge: Bool
    let isLoading: Bool
    let isPinned: Bool
}

struct WorkspaceLayoutTabChromeDebugAppearanceSpec: Codable {
    let tabBarHeight: Double
    let tabMinWidth: Double
    let tabMaxWidth: Double
    let tabTitleFontSize: Double
    let tabSpacing: Double
    let minimumPaneWidth: Double
    let minimumPaneHeight: Double
    let showSplitButtons: Bool
    let splitButtonsOnHover: Bool
    let tabBarLeadingInset: Double
    let splitButtonTooltips: WorkspaceLayoutTabChromeDebugSplitButtonTooltipsSpec
    let animationDuration: Double
    let enableAnimations: Bool
    let chromeColors: WorkspaceLayoutTabChromeDebugChromeColorsSpec
}

struct WorkspaceLayoutTabChromeDebugSplitButtonTooltipsSpec: Codable {
    let newTerminal: String
    let newBrowser: String
    let splitRight: String
    let splitDown: String
}

struct WorkspaceLayoutTabChromeDebugChromeColorsSpec: Codable {
    let backgroundHex: String?
    let borderHex: String?
}

struct WorkspaceLayoutReferenceTabChromeView: View {
    let tab: WorkspaceLayout.Tab
    let isSelected: Bool
    let isHovered: Bool
    let isCloseHovered: Bool
    let isClosePressed: Bool
    let showsZoomIndicator: Bool
    let isZoomHovered: Bool
    let isZoomPressed: Bool
    let appearance: WorkspaceLayoutConfiguration.Appearance
    let fixedSpinnerPhase: Double?
    let saturation: Double = 1.0

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: TabBarMetrics.contentSpacing) {
                let iconSlotSize = TabBarMetrics.iconSize
                let iconTint = isSelected
                    ? TabBarColors.activeText(for: appearance)
                    : TabBarColors.inactiveText(for: appearance)
                let faviconImage = decodedFaviconImage

                Group {
                    if tab.isLoading {
                        WorkspaceLayoutReferenceTabLoadingSpinner(
                            size: iconSlotSize * 0.86,
                            color: iconTint,
                            fixedPhaseDegrees: fixedSpinnerPhase
                        )
                    } else if let image = faviconImage {
                        WorkspaceLayoutReferenceFaviconIconView(image: image)
                            .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)
                            .clipped()
                    } else if let iconName = tab.icon {
                        Image(systemName: iconName)
                            .font(.system(size: glyphSize(for: iconName)))
                            .foregroundStyle(iconTint)
                    }
                }
                .saturation(WorkspaceLayoutReferenceTabItemStyling.iconSaturation(hasRasterIcon: faviconImage != nil, tabSaturation: saturation))
                .transaction { tx in
                    tx.animation = nil
                }
                .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)

                Text(tab.title)
                    .font(.system(size: appearance.tabTitleFontSize))
                    .lineLimit(1)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .saturation(saturation)

                if showsZoomIndicator {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: max(8, appearance.tabTitleFontSize - 2), weight: .semibold))
                        .foregroundStyle(
                            isZoomHovered
                                ? TabBarColors.activeText(for: appearance)
                                : TabBarColors.inactiveText(for: appearance)
                        )
                        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                        .background(
                            Circle()
                                .fill(
                                    isZoomHovered
                                        ? TabBarColors.hoveredTabBackground(for: appearance)
                                        : .clear
                                )
                        )
                        .saturation(saturation)
                }
            }

            Spacer(minLength: 0)

            trailingAccessory
        }
        .padding(.horizontal, TabBarMetrics.tabHorizontalPadding)
        .offset(y: isSelected ? 0.5 : 0)
        .frame(
            minWidth: TabBarMetrics.tabMinWidth,
            maxWidth: TabBarMetrics.tabMaxWidth,
            minHeight: TabBarMetrics.tabHeight,
            maxHeight: TabBarMetrics.tabHeight
        )
        .padding(.bottom, isSelected ? 1 : 0)
        .background(tabBackground)
        .allowsHitTesting(false)
    }

    var decodedFaviconImage: NSImage? {
        guard let data = tab.iconImageData,
              let image = NSImage(data: data) else {
            return nil
        }
        image.isTemplate = false
        return image
    }

    func glyphSize(for iconName: String) -> CGFloat {
        if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
            return max(10, TabBarMetrics.iconSize - 2.5)
        }
        return TabBarMetrics.iconSize
    }

    @ViewBuilder
    var trailingAccessory: some View {
        closeOrDirtyIndicator
            .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
            .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isHovered)
            .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isCloseHovered)
    }

    @ViewBuilder
    var tabBackground: some View {
        ZStack(alignment: .top) {
            if WorkspaceLayoutReferenceTabItemStyling.shouldShowHoverBackground(isHovered: isHovered, isSelected: isSelected) {
                Rectangle()
                    .fill(TabBarColors.hoveredTabBackground(for: appearance))
            } else {
                Color.clear
            }

            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: TabBarMetrics.activeIndicatorHeight)
            }

            HStack {
                Spacer()
                Rectangle()
                    .fill(TabBarColors.separator(for: appearance))
                    .frame(width: 1)
            }
        }
    }

    @ViewBuilder
    var closeOrDirtyIndicator: some View {
        ZStack {
            if (!isSelected && !isHovered && !isCloseHovered) && (tab.isDirty || tab.showsNotificationBadge) {
                HStack(spacing: 2) {
                    if tab.showsNotificationBadge {
                        Circle()
                            .fill(TabBarColors.notificationBadge(for: appearance))
                            .frame(width: TabBarMetrics.notificationBadgeSize, height: TabBarMetrics.notificationBadgeSize)
                    }
                    if tab.isDirty {
                        Circle()
                            .fill(TabBarColors.dirtyIndicator(for: appearance))
                            .frame(width: TabBarMetrics.dirtyIndicatorSize, height: TabBarMetrics.dirtyIndicatorSize)
                            .saturation(saturation)
                    }
                }
            }

            if tab.isPinned {
                if isSelected || isHovered || isCloseHovered || (!tab.isDirty && !tab.showsNotificationBadge) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(TabBarColors.inactiveText(for: appearance))
                        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                        .saturation(saturation)
                }
            } else if isSelected || isHovered || isCloseHovered {
                Image(systemName: "xmark")
                    .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                    .foregroundStyle(
                        isCloseHovered
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                    .background(
                        Circle()
                            .fill(
                                isCloseHovered
                                    ? TabBarColors.hoveredTabBackground(for: appearance)
                                    : .clear
                            )
                    )
                    .saturation(saturation)
            }
        }
    }
}

enum WorkspaceLayoutReferenceTabItemStyling {
    static func iconSaturation(hasRasterIcon: Bool, tabSaturation: Double) -> Double {
        hasRasterIcon ? 1.0 : tabSaturation
    }

    static func shouldShowHoverBackground(isHovered: Bool, isSelected: Bool) -> Bool {
        isHovered && !isSelected
    }
}

struct WorkspaceLayoutReferenceTabLoadingSpinner: View {
    let size: CGFloat
    let color: Color
    let fixedPhaseDegrees: Double?

    var body: some View {
        TimelineView(.animation) { context in
            ZStack {
                Circle()
                    .stroke(color.opacity(0.20), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0.0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(spinnerAngle(for: context.date)))
            }
            .frame(width: size, height: size)
        }
    }

    var ringWidth: CGFloat {
        max(1.6, size * 0.14)
    }

    func spinnerAngle(for date: Date) -> Double {
        if let fixedPhaseDegrees {
            return fixedPhaseDegrees
        }
        let t = date.timeIntervalSinceReferenceDate
        return (t.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360.0
    }
}

struct WorkspaceLayoutReferenceFaviconIconView: NSViewRepresentable {
    let image: NSImage

    final class ContainerView: NSView {
        let imageView = NSImageView(frame: .zero)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            imageView.imageScaling = .scaleProportionallyDown
            imageView.imageAlignment = .alignCenter
            imageView.animates = false
            imageView.contentTintColor = nil
            imageView.autoresizingMask = [.width, .height]
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func layout() {
            super.layout()
            imageView.frame = bounds.integral
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        ContainerView(frame: .zero)
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        image.isTemplate = false
        if nsView.imageView.image !== image {
            nsView.imageView.image = image
        }
        nsView.imageView.contentTintColor = nil
    }
}
