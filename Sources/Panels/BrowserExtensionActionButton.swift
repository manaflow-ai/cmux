import AppKit
import CmuxBrowser
import SwiftUI

/// One pinned extension action in the browser toolbar (design spec §3a).
///
/// An accessory-sized button (`BrowserChromeMetrics.buttonIconSize`) showing
/// the icon Chromium composites for this tab (badge and disabled state
/// included, as Chrome's toolbar draws it) at
/// `extensionActionIconSize`. A crashed extension shows a warning glyph and
/// reloads on click. Receives value snapshots plus closures only.
struct BrowserExtensionActionButton: View {
    let action: BrowserExtensionAction
    let isCrashed: Bool
    let isPopupOpen: Bool
    let metrics: BrowserChromeMetrics
    let onRun: (CGRect) -> Void
    let onReload: () -> Void
    let onContextMenu: (CGPoint) -> Void

    @State private var globalFrame: CGRect = .zero

    var body: some View {
        Button {
            if isCrashed { onReload() } else { onRun(globalFrame) }
        } label: {
            icon
                .frame(width: metrics.buttonIconSize, height: metrics.buttonIconSize, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(OmnibarAddressButtonStyle(isActive: isPopupOpen))
        .frame(width: metrics.buttonIconSize, height: metrics.buttonIconSize, alignment: .center)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { globalFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in globalFrame = frame }
            }
        }
        .contextMenu {
            Button(String(localized: "browser.extensions.siteAccess", defaultValue: "Site Access and More…")) {
                onContextMenu(NSEvent.mouseLocation)
            }
        }
        .safeHelp(helpText)
        .accessibilityLabel(helpText)
        .accessibilityIdentifier("BrowserExtensionAction.\(action.id)")
    }

    private var helpText: String {
        if isCrashed {
            return String(
                format: String(localized: "browser.extensions.crashedHelp", defaultValue: "Crashed: %@. Click to reload."),
                action.name
            )
        }
        return action.title.isEmpty ? action.name : action.title
    }

    @ViewBuilder private var icon: some View {
        if isCrashed {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: metrics.accessoryIconFontSize, weight: .medium))
                .foregroundStyle(.secondary)
        } else if let data = action.iconPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: metrics.extensionActionIconSize, height: metrics.extensionActionIconSize)
                .opacity(action.isEnabled ? 1 : 0.4)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: metrics.accessoryIconFontSize, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
