import AppKit
import SwiftUI
import WebKit

/// Toolbar buttons for loaded web extensions: one button per extension action,
/// anchored so the extension's popup (e.g. the Bitwarden vault) opens beneath it.
@available(macOS 15.4, *)
struct BrowserWebExtensionToolbarButtons: View {
    let support: BrowserWebExtensionSupport
    let panel: BrowserPanel
    let iconPointSize: CGFloat
    let hitSize: CGFloat

    var body: some View {
        ForEach(support.actionSnapshots) { snapshot in
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
        }
    }
}

@available(macOS 15.4, *)
private struct BrowserWebExtensionActionButton: View {
    let snapshot: BrowserWebExtensionActionSnapshot
    let panel: BrowserPanel
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let performAction: (NSView?) -> Void

    @State private var anchorViewHolder = BrowserWebExtensionAnchorViewHolder()

    var body: some View {
        Button(action: {
#if DEBUG
            cmuxDebugLog(
                "browser.webext.action panel=\(panel.id.uuidString.prefix(5)) " +
                "name=\(snapshot.displayName)"
            )
#endif
            performAction(anchorViewHolder.view)
        }) {
            actionIcon
                .frame(width: hitSize, height: hitSize, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .background(BrowserWebExtensionAnchorViewReader(holder: anchorViewHolder))
        .safeHelp(snapshot.displayName)
        .accessibilityIdentifier(snapshot.accessibilityIdentifier)
    }

    @ViewBuilder
    private var actionIcon: some View {
        if let icon = snapshot.icon {
            Image(nsImage: icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: iconPointSize + 3, height: iconPointSize + 3)
        } else {
            CmuxSystemSymbolImage(
                systemName: "puzzlepiece.extension",
                pointSize: iconPointSize,
                weight: .medium
            )
        }
    }
}

/// Captures the hosting `NSView` behind a SwiftUI button so an `NSPopover`
/// (the extension action popup) can anchor to it.
@available(macOS 15.4, *)
@MainActor
private final class BrowserWebExtensionAnchorViewHolder {
    weak var view: NSView?
}

@available(macOS 15.4, *)
private struct BrowserWebExtensionAnchorViewReader: NSViewRepresentable {
    let holder: BrowserWebExtensionAnchorViewHolder

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        holder.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        holder.view = nsView
    }
}
