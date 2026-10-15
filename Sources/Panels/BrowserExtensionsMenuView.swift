import AppKit
import CmuxBrowser
import SwiftUI

/// The Extensions popover of a Chromium browser panel (design spec §3a).
///
/// Styled like Classic's profile popover (rows 24 × scale, radius 6) with a
/// header, one row per extension (icon, name, pin toggle, more menu), and a
/// footer (Load Unpacked…, Chrome Web Store, Manage Extensions). Receives
/// value snapshots plus one action closure (snapshot-boundary rule).
/// Refs: cmux-design-references `apps/claude/live/browser-settings-menu.png`
/// (grouped, separators, destructive in red), `apps/cursor/live/customize-plugin-browser.png`;
/// cmux Next `ExtensionsMenu.swift`; Chrome's extensions menu wording.
struct BrowserExtensionsMenuView: View {
    /// What the person chose in the popover.
    enum Choice: Equatable {
        case run(String)
        case pin(String, Bool)
        case options(String)
        case setEnabled(String, Bool)
        case reload(String)
        case remove(String)
        case siteAccess(String)
        case loadUnpacked
        case webStore
        case manage
    }

    let extensions: [BrowserExtensionInfo]
    let actionIDs: Set<String>
    /// Pinned extensions whose actions don't fit the toolbar row; listed first under "Pinned".
    var overflowedIDs: [String] = []
    let supportsManagement: Bool
    let metrics: BrowserChromeMetrics
    let onChoice: (Choice) -> Void

    @State private var pendingRemoval: BrowserExtensionInfo?
    /// The name in the remove confirmation; kept while the dialog dismisses so it never reads "Remove “”?".
    @State private var removalName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "browser.toolbar.extensions", defaultValue: "Extensions"))
                .cmuxFont(size: 12, weight: .semibold)
                .foregroundStyle(.secondary)
                .accessibilityAddTraits(.isHeader)

            if extensions.isEmpty {
                Text(String(localized: "browser.extensions.none", defaultValue: "No extensions installed"))
                    .cmuxFont(size: 12)
                    .foregroundStyle(.secondary)
                    .frame(height: metrics.extensionsMenuRowHeight)
            } else {
                let overflowed = overflowedIDs.compactMap { id in extensions.first { $0.id == id } }
                if !overflowed.isEmpty {
                    Text(String(localized: "browser.extensions.pinnedHeader", defaultValue: "Pinned"))
                        .cmuxFont(size: metrics.extensionsMenuCaptionFontSize, weight: .medium)
                        .foregroundStyle(.secondary)
                        .accessibilityAddTraits(.isHeader)
                    rows(overflowed)
                    Divider()
                }
                rows(extensions.filter { !overflowedIDs.contains($0.id) })
            }

            Divider()

            if supportsManagement {
                footerButton(.loadUnpacked, title: String(localized: "browser.extensions.loadUnpacked", defaultValue: "Load Unpacked…"))
            }
            footerButton(.webStore, title: String(localized: "browser.extensions.webStore", defaultValue: "Chrome Web Store"))
            footerButton(.manage, title: String(localized: "browser.extensions.manage", defaultValue: "Manage Extensions"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(minWidth: metrics.extensionsMenuMinimumWidth, alignment: .leading)
        .accessibilityIdentifier("browser.extensions.menu")
        .confirmationDialog(
            removalTitle,
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button(String(localized: "browser.extensions.removeConfirm", defaultValue: "Remove"), role: .destructive) {
                if let info = pendingRemoval { onChoice(.remove(info.id)) }
                pendingRemoval = nil
            }
            Button(String(localized: "browser.extensions.cancel", defaultValue: "Cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            Text(String(localized: "browser.extensions.removeMessage",
                        defaultValue: "Its data in this browser profile is deleted too."))
        }
    }

    private func rows(_ list: [BrowserExtensionInfo]) -> some View {
        VStack(alignment: .leading, spacing: metrics.extensionsMenuRowSpacing) {
            ForEach(list) { info in
                BrowserExtensionsMenuRow(
                    info: info,
                    canRun: actionIDs.contains(info.id),
                    supportsManagement: supportsManagement,
                    metrics: metrics,
                    onChoice: { choice in
                        if case .remove = choice {
                            removalName = info.name
                            pendingRemoval = info
                        } else {
                            onChoice(choice)
                        }
                    }
                )
            }
        }
    }

    private var removalTitle: String {
        String(
            format: String(localized: "browser.extensions.removeTitle", defaultValue: "Remove \u{201C}%@\u{201D}?"),
            removalName
        )
    }

    private func footerButton(_ choice: Choice, title: String) -> some View {
        Button {
            onChoice(choice)
        } label: {
            Text(title)
                .cmuxFont(size: 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("browser.extensions.menu.\(String(describing: choice))")
    }
}
