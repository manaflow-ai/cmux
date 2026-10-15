import AppKit
import CmuxBrowser
import SwiftUI

/// One extension in the Extensions popover: icon, name (click runs its
/// action), pin toggle and a more menu (design spec §3a).
struct BrowserExtensionsMenuRow: View {
    let info: BrowserExtensionInfo
    let canRun: Bool
    let supportsManagement: Bool
    let metrics: BrowserChromeMetrics
    let onChoice: (BrowserExtensionsMenuView.Choice) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: metrics.extensionsMenuSpacing) {
            if info.isTerminated || canRun {
                Button {
                    if info.isTerminated { onChoice(.reload(info.id)) } else { onChoice(.run(info.id)) }
                } label: {
                    rowLabel
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("browser.extensions.menu.row.\(info.id)")
            } else {
                // No toolbar action: inert, but not dimmed (only a disabled extension reads as off).
                rowLabel
                    .accessibilityIdentifier("browser.extensions.menu.row.\(info.id)")
            }

            if supportsManagement && info.hasAction {
                Button {
                    onChoice(.pin(info.id, !info.isPinned))
                } label: {
                    Image(systemName: info.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: metrics.accessoryIconFontSize, weight: .medium))
                        .foregroundStyle(info.isPinned ? .primary : .secondary)
                        .frame(width: metrics.extensionsMenuRowHeight, height: metrics.extensionsMenuRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(OmnibarAddressButtonStyle())
                .safeHelp(info.isPinned ? unpinTitle : pinTitle)
                .accessibilityLabel(info.isPinned ? unpinTitle : pinTitle)
                .accessibilityIdentifier("browser.extensions.menu.pin.\(info.id)")
            }

            moreMenu
        }
        .padding(.leading, metrics.extensionsMenuSpacing)
        .frame(height: metrics.extensionsMenuRowHeight)
        .background(
            RoundedRectangle(cornerRadius: metrics.extensionsMenuRowCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
        )
        .onHover { isHovered = $0 }
    }

    private var rowLabel: some View {
        HStack(spacing: metrics.extensionsMenuSpacing) {
            icon
            Text(info.name)
                .cmuxFont(size: metrics.extensionsMenuFontSize)
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(info.isEnabled || info.isTerminated ? .primary : .secondary)
            if info.isTerminated {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: metrics.secureBadgeFontSize, weight: .medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(String(
                        format: String(localized: "browser.extensions.crashedHelp", defaultValue: "Crashed: %@. Click to reload."),
                        info.name
                    ))
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private var pinTitle: String { String(localized: "browser.extensions.pin", defaultValue: "Pin to Toolbar") }
    private var unpinTitle: String { String(localized: "browser.extensions.unpin", defaultValue: "Unpin from Toolbar") }

    @ViewBuilder private var icon: some View {
        if let path = info.iconPath, let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: metrics.extensionsMenuIconSize, height: metrics.extensionsMenuIconSize)
                .opacity(info.isEnabled ? 1 : 0.5)
        } else {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: metrics.accessoryIconFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: metrics.extensionsMenuIconSize, height: metrics.extensionsMenuIconSize)
        }
    }

    private var moreMenu: some View {
        Menu {
            if supportsManagement {
                if info.hasAction {
                    Button(info.isPinned ? unpinTitle : pinTitle) { onChoice(.pin(info.id, !info.isPinned)) }
                }
                if info.optionsURL != nil {
                    Button(String(localized: "browser.extensions.options", defaultValue: "Options")) { onChoice(.options(info.id)) }
                }
                Button(String(localized: "browser.extensions.siteAccess", defaultValue: "Site Access and More…")) {
                    onChoice(.siteAccess(info.id))
                }
                .disabled(!info.hasAction)
                Divider()
                if info.canToggle {
                    if info.isEnabled {
                        Button(String(localized: "browser.extensions.disable", defaultValue: "Disable")) { onChoice(.setEnabled(info.id, false)) }
                    } else {
                        Button(String(localized: "browser.extensions.enable", defaultValue: "Enable")) { onChoice(.setEnabled(info.id, true)) }
                    }
                }
                Button(String(localized: "browser.extensions.reload", defaultValue: "Reload")) { onChoice(.reload(info.id)) }
                if info.canRemove {
                    Divider()
                    Button(String(localized: "browser.extensions.remove", defaultValue: "Remove…"), role: .destructive) {
                        onChoice(.remove(info.id))
                    }
                }
            } else {
                Button(String(localized: "browser.extensions.manage", defaultValue: "Manage Extensions")) { onChoice(.manage) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: metrics.accessoryIconFontSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: metrics.extensionsMenuRowHeight, height: metrics.extensionsMenuRowHeight)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: metrics.extensionsMenuRowHeight, height: metrics.extensionsMenuRowHeight)
        .safeHelp(String(
            format: String(localized: "browser.extensions.moreFormat", defaultValue: "More Actions for %@"),
            info.name
        ))
        .accessibilityIdentifier("browser.extensions.menu.more.\(info.id)")
    }
}
