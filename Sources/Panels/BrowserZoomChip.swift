import AppKit
import CmuxBrowser
import SwiftUI

/// The browser toolbar's zoom chip: the page's zoom as a quiet text capsule ("125%"), shown while
/// the zoom differs from the default. Clicking it opens Chrome's zoom bubble: − · percentage · +
/// · Reset. Zoom shortcuts open the same popover for a moment (design spec §7,
/// Chrome `zoom_bubble_view.cc`).
struct BrowserZoomChip: View {
    let model: BrowserZoomIndicatorModel
    let metrics: BrowserChromeMetrics
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let reset: () -> Void

    var body: some View {
        if model.isChipVisible {
            Button(action: model.showFromChip) {
                Text(Self.percentText(model.factor))
                    .font(.system(size: metrics.zoomChipFontSize, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, metrics.zoomChipHorizontalPadding)
                    .padding(.vertical, metrics.zoomChipVerticalPadding)
                    .frame(height: metrics.zoomChipHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(OmnibarAddressButtonStyle())
            .safeHelp(String(localized: "browser.zoom.chip.help", defaultValue: "Zoom Controls"))
            .accessibilityIdentifier("browser.zoom.chip")
            .accessibilityLabel(String(localized: "browser.zoom.chip.accessibility", defaultValue: "Page zoom"))
            .accessibilityValue(Self.percentText(model.factor))
            .popover(isPresented: popoverBinding, arrowEdge: .bottom) {
                BrowserZoomPopover(model: model, metrics: metrics, zoomIn: zoomIn, zoomOut: zoomOut, reset: reset)
            }
            .transition(.opacity)
        }
    }

    private var popoverBinding: Binding<Bool> {
        Binding(get: { model.isPopoverShown }, set: { shown in if !shown { model.dismiss() } })
    }

    /// The zoom factor as a locale-formatted whole percentage ("125%", "125 %").
    static func percentText(_ factor: Double) -> String {
        (Double(BrowserZoomLadder.percent(factor)) / 100).formatted(.percent.precision(.fractionLength(0)))
    }
}

/// Chrome's zoom bubble: − · percentage · + · Reset. Pressing a button keeps it open five seconds;
/// hovering keeps it open.
private struct BrowserZoomPopover: View {
    let model: BrowserZoomIndicatorModel
    let metrics: BrowserChromeMetrics
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let reset: () -> Void

    var body: some View {
        HStack(spacing: metrics.zoomPopoverPadding) {
            stepButton(
                systemImage: "minus",
                label: String(localized: "menu.view.zoomOut", defaultValue: "Zoom Out"),
                identifier: "browser.zoom.out",
                action: zoomOut
            )
            Text(BrowserZoomChip.percentText(model.factor))
                .font(.system(size: metrics.zoomPopoverFontSize, weight: .medium).monospacedDigit())
                .frame(minWidth: metrics.zoomPopoverButtonSize * 2)
                .accessibilityIdentifier("browser.zoom.value")
            stepButton(
                systemImage: "plus",
                label: String(localized: "menu.view.zoomIn", defaultValue: "Zoom In"),
                identifier: "browser.zoom.in",
                action: zoomIn
            )
            Button(String(localized: "browser.zoom.reset", defaultValue: "Reset")) {
                model.noteButtonPress()
                reset()
            }
            .controlSize(.small)
            .accessibilityIdentifier("browser.zoom.reset")
        }
        .padding(metrics.zoomPopoverPadding)
        .onHover { model.isHovered = $0 }
    }

    private func stepButton(systemImage: String, label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button {
            model.noteButtonPress()
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: metrics.zoomPopoverFontSize, weight: .medium))
                .frame(width: metrics.zoomPopoverButtonSize, height: metrics.zoomPopoverButtonSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .safeHelp(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}
