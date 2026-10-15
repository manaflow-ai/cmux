import AppKit
import CmuxBrowser
import SwiftUI

/// The extension part of a Chromium panel's toolbar row (design spec §3a):
/// up to six pinned actions, then the Extensions (puzzle) button.
///
/// Shown only when the panel's page hosts extensions and at least one is
/// installed, so a fresh Chromium panel's row matches WebKit's. In compact
/// panes the pinned actions fold into the Extensions popover. Reads the
/// observable host here and passes value snapshots down.
struct BrowserExtensionToolbar: View {
    let host: any BrowserExtensionHosting
    let metrics: BrowserChromeMetrics
    let isCompact: Bool
    let spacing: CGFloat
    let tint: Color
    /// The page view's leading edge in window coordinates, to anchor popups.
    let pageLeadingX: () -> CGFloat?
    let onChoice: (BrowserExtensionsMenuView.Choice) -> Void

    @State private var isMenuPresented = false
    @State private var menuButtonFrame: CGRect = .zero
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let store = host.extensionStore
        let extensions = store.extensions
        let actions = host.extensionActions
        let crashed = Set(store.crashed.map(\.id))
        let pinned = isCompact ? [] : Array(actions.filter(\.isPinned).prefix(BrowserChromeMetrics.maximumPinnedExtensionActions))
        Group {
            if !extensions.isEmpty || !actions.isEmpty {
                HStack(spacing: spacing) {
                    ForEach(pinned) { action in
                        BrowserExtensionActionButton(
                            action: action,
                            isCrashed: crashed.contains(action.id),
                            isPopupOpen: host.openExtensionPopup == action.id,
                            metrics: metrics,
                            onRun: { frame in run(action.id, buttonFrame: frame) },
                            onReload: { _ = store.reload(action.id) },
                            onContextMenu: { point in host.showExtensionActionMenu(action.id, atScreenPoint: point) }
                        )
                    }
                    menuButton(extensions: extensions, actionIDs: Set(actions.map(\.id)), supportsManagement: store.supportsManagement)
                }
            }
        }
        .onAppear {
            store.refresh()
            host.refreshExtensionActions()
        }
    }

    private func menuButton(extensions: [BrowserExtensionInfo], actionIDs: Set<String>, supportsManagement: Bool) -> some View {
        Button {
            isMenuPresented.toggle()
        } label: {
            CmuxSystemSymbolImage(systemName: "puzzlepiece.extension", pointSize: metrics.accessoryIconFontSize, weight: .medium, tint: tint)
                .frame(width: metrics.buttonIconSize, height: metrics.buttonIconSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle(isActive: isMenuPresented))
        .frame(width: metrics.buttonIconSize, height: metrics.buttonIconSize, alignment: .center)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { menuButtonFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in menuButtonFrame = frame }
            }
        }
        .popover(isPresented: $isMenuPresented, arrowEdge: .bottom) {
            BrowserExtensionsMenuView(
                extensions: extensions,
                actionIDs: actionIDs,
                supportsManagement: supportsManagement,
                metrics: metrics,
                onChoice: { choice in
                    isMenuPresented = false
                    if case .run(let id) = choice {
                        // Unpinned actions hang their popup below the Extensions button.
                        run(id, buttonFrame: menuButtonFrame)
                    } else {
                        onChoice(choice)
                    }
                }
            )
            .browserChromePopoverAppearance(colorScheme)
        }
        .safeHelp(String(localized: "browser.toolbar.extensions", defaultValue: "Extensions"))
        .accessibilityLabel(String(localized: "browser.toolbar.extensions", defaultValue: "Extensions"))
        .accessibilityIdentifier("BrowserExtensionsButton")
    }

    /// Runs an action with its popup below `buttonFrame` (SwiftUI global =
    /// window coordinates), converted to the page view's x.
    private func run(_ id: String, buttonFrame: CGRect) {
        let leading = pageLeadingX() ?? 0
        let anchor = CGRect(x: max(buttonFrame.minX - leading, 0), y: 0, width: max(buttonFrame.width, 1), height: 1)
        host.runExtensionAction(id, anchor: anchor)
    }
}
