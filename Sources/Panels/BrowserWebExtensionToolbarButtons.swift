import AppKit
import SwiftUI

/// Toolbar buttons for loaded web extensions: one button per extension action,
/// anchored so the extension's popup (e.g. the Bitwarden vault) opens beneath it.
@available(macOS 15.4, *)
struct BrowserWebExtensionToolbarButtons: View {
    let support: BrowserWebExtensionSupport
    let panel: BrowserPanel
    let iconPointSize: CGFloat
    let hitSize: CGFloat

    var body: some View {
        let snapshots = support.actionSnapshots(for: panel.id)
        ForEach(snapshots.filter(\.showsToolbarButton)) { snapshot in
            BrowserWebExtensionActionButton(
                snapshot: snapshot,
                panel: panel,
                iconPointSize: iconPointSize,
                hitSize: hitSize,
                performAction: { anchorView in
                    guard let context = support.context(forActionID: snapshot.id) else { return }
                    support.performAction(context: context, panel: panel, anchorView: anchorView)
                }
            )
            // Right-click any extension button to choose which extensions show
            // a toolbar button, without leaving the browser.
            .contextMenu {
                visibilityToggles(snapshots)
            }
        }
        if snapshots.contains(where: { !$0.showsToolbarButton }) {
            Menu {
                visibilityToggles(snapshots)
            } label: {
                CmuxSystemSymbolImage(
                    systemName: "puzzlepiece.extension",
                    pointSize: iconPointSize,
                    weight: .medium
                )
                .frame(width: hitSize, height: hitSize, alignment: .center)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: hitSize, height: hitSize, alignment: .center)
            .safeHelp(String(
                localized: "settings.browser.webExtensions",
                defaultValue: "Extensions"
            ))
            .accessibilityIdentifier("BrowserWebExtensionVisibilityMenu")
        }
    }

    @ViewBuilder
    private func visibilityToggles(_ snapshots: [BrowserWebExtensionActionSnapshot]) -> some View {
        ForEach(snapshots) { snapshot in
            Toggle(isOn: Binding(
                get: { snapshot.showsToolbarButton },
                set: { support.setToolbarButtonVisible($0, entryID: snapshot.id) }
            )) {
                Text(snapshot.displayName)
            }
            .disabled(!snapshot.canToggleToolbarButton)
        }
    }
}
