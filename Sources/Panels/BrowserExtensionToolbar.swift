import AppKit
import CmuxBrowser
import SwiftUI

/// The extension part of a Chromium panel's toolbar row (design spec §3a,
/// §3a-bis): the pinned actions that fit, then the Extensions (puzzle)
/// button, then one group gap before the cmux accessories.
///
/// Shown only when the panel's page hosts extensions and at least one is
/// installed, so a fresh Chromium panel's row matches WebKit's. Pins that
/// don't fit the row (``BrowserExtensionToolbarBudget``) leave from the left
/// and appear first in the Extensions popover. Reads the observable host
/// here and passes value snapshots down.
struct BrowserExtensionToolbar: View {
    let host: any BrowserExtensionHosting
    let metrics: BrowserChromeMetrics
    /// The toolbar row's width, for the pinned-action budget.
    let rowWidth: CGFloat
    /// The cmux accessory buttons after the extension cluster at this width.
    let trailingAccessoryCount: Int
    let spacing: CGFloat
    let tint: Color
    /// The page view's leading edge in window coordinates, to anchor popups.
    let pageLeadingX: () -> CGFloat?
    let onChoice: (BrowserExtensionsMenuView.Choice) -> Void

    @State private var isMenuPresented = false
    @State private var menuAnchor = BrowserExtensionAnchor()
    @State private var buttonAnchors = BrowserExtensionAnchorSet()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let store = host.extensionStore
        let extensions = store.extensions
        let actions = host.extensionActions
        let crashed = Set(store.crashed.map(\.id))
        let budget = BrowserExtensionToolbarBudget(
            rowWidth: rowWidth, scale: metrics.scale, trailingAccessoryCount: trailingAccessoryCount
        )
        let split = budget.split(actions.filter(\.isPinned).map(\.id))
        let visibleIDs = Set(split.visible)
        let pinned = actions.filter { visibleIDs.contains($0.id) }
        let overflowed = split.overflowed
        // An overflowed action's popup hangs below the Extensions button, which then shows the active fill.
        let menuActive = isMenuPresented || host.openExtensionPopup.map { !visibleIDs.contains($0) } == true
        Group {
            if !extensions.isEmpty || !actions.isEmpty {
                HStack(spacing: spacing) {
                    ForEach(pinned) { action in
                        BrowserExtensionActionButton(
                            action: action,
                            isCrashed: crashed.contains(action.id),
                            isPopupOpen: host.openExtensionPopup == action.id,
                            metrics: metrics,
                            anchor: buttonAnchors.anchor(for: action.id),
                            onRun: { frame in
                                // A second click on the button closes its open popup (Chrome's toggle).
                                if host.openExtensionPopup == action.id {
                                    host.hideExtensionPopup()
                                } else {
                                    run(action.id, buttonFrame: frame)
                                }
                            },
                            onReload: { _ = store.reload(action.id) },
                            onContextMenu: { point in host.showExtensionActionMenu(action.id, atScreenPoint: point) }
                        )
                    }
                    menuButton(
                        extensions: extensions, actionIDs: Set(actions.map(\.id)), overflowedIDs: overflowed,
                        supportsManagement: store.supportsManagement, isActive: menuActive
                    )
                }
                // One group gap between the extension cluster and the cmux accessories.
                .padding(.trailing, max(metrics.extensionsGroupGap - spacing, 0))
            }
        }
        .onAppear {
            store.refresh()
            host.refreshExtensionActions()
            // Actions run by a shortcut or the CLI hang below their pinned
            // button when it is shown, else below the Extensions button.
            host.extensionActionRequestHandler = { [buttonAnchors, menuAnchor] id in
                let frame = buttonAnchors.windowFrame(for: id) ?? menuAnchor.windowFrame ?? .zero
                run(id, buttonFrame: frame)
            }
        }
    }

    private func menuButton(
        extensions: [BrowserExtensionInfo], actionIDs: Set<String>, overflowedIDs: [String],
        supportsManagement: Bool, isActive: Bool
    ) -> some View {
        Button {
            isMenuPresented.toggle()
        } label: {
            CmuxSystemSymbolImage(systemName: "puzzlepiece.extension", pointSize: metrics.accessoryIconFontSize, weight: .medium, tint: tint)
                .frame(width: metrics.buttonIconSize, height: metrics.buttonIconSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle(isActive: isActive))
        .frame(width: metrics.buttonIconSize, height: metrics.buttonIconSize, alignment: .center)
        .background(BrowserExtensionAnchorReader(anchor: menuAnchor))
        .popover(isPresented: $isMenuPresented, arrowEdge: .bottom) {
            BrowserExtensionsMenuView(
                extensions: extensions,
                actionIDs: actionIDs,
                overflowedIDs: overflowedIDs,
                supportsManagement: supportsManagement,
                metrics: metrics,
                onChoice: { choice in
                    isMenuPresented = false
                    if case .run(let id) = choice {
                        // Unpinned actions hang their popup below the Extensions button.
                        run(id, buttonFrame: menuAnchor.windowFrame ?? .zero)
                    } else {
                        onChoice(choice)
                    }
                }
            )
            .browserChromePopoverAppearance(colorScheme)
        }
        .safeHelp(String(localized: "browser.toolbar.extensions", defaultValue: "Extensions"))
        .accessibilityLabel(String(localized: "browser.toolbar.extensions", defaultValue: "Extensions"))
        .accessibilityHint(BrowserExtensionAccessibilityText.showsExtensionsHint)
        .accessibilityAddTraits(isMenuPresented ? .isSelected : [])
        .accessibilityIdentifier("BrowserExtensionsButton")
    }

    /// Runs an action with its popup below `buttonFrame` (window
    /// coordinates), converted to the page view's x.
    private func run(_ id: String, buttonFrame: CGRect) {
        let leading = pageLeadingX() ?? 0
        let anchor = CGRect(x: max(buttonFrame.minX - leading, 0), y: 0, width: max(buttonFrame.width, 1), height: 1)
        host.runExtensionAction(id, anchor: anchor)
    }
}
