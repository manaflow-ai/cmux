import AppKit
import SwiftUI
import WebKit

/// Toolbar buttons for loaded web extensions: one button per extension action,
/// anchored so the extension's popup (e.g. the Bitwarden vault) opens beneath it.
@available(macOS 15.4, *)
struct BrowserWebExtensionToolbarButtons: View {
    @ObservedObject var support: BrowserWebExtensionSupport
    let panel: BrowserPanel
    let iconPointSize: CGFloat
    let hitSize: CGFloat

    var body: some View {
        ForEach(Array(support.contexts.enumerated()), id: \.offset) { _, context in
            BrowserWebExtensionActionButton(
                support: support,
                context: context,
                panel: panel,
                iconPointSize: iconPointSize,
                hitSize: hitSize
            )
        }
    }
}

@available(macOS 15.4, *)
private struct BrowserWebExtensionActionButton: View {
    let support: BrowserWebExtensionSupport
    let context: WKWebExtensionContext
    let panel: BrowserPanel
    let iconPointSize: CGFloat
    let hitSize: CGFloat

    @State private var anchorViewHolder = BrowserWebExtensionAnchorViewHolder()

    var body: some View {
        Button(action: {
#if DEBUG
            cmuxDebugLog(
                "browser.webext.action panel=\(panel.id.uuidString.prefix(5)) " +
                "name=\(context.webExtension.displayName ?? "?")"
            )
#endif
            support.performAction(context: context, panel: panel, anchorView: anchorViewHolder.view)
        }) {
            actionIcon
                .frame(width: hitSize, height: hitSize, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .background(BrowserWebExtensionAnchorViewReader(holder: anchorViewHolder))
        .safeHelp(context.webExtension.displayName ?? String(
            localized: "browser.webExtension.action.help",
            defaultValue: "Extension"
        ))
        .accessibilityIdentifier("BrowserWebExtensionActionButton")
    }

    @ViewBuilder
    private var actionIcon: some View {
        if let icon = context.webExtension.icon(for: CGSize(width: 32, height: 32)) {
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
