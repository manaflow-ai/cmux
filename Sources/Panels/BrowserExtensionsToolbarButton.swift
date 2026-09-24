import AppKit
import CmuxBrowser
import SwiftUI

/// The puzzle-piece button in the browser toolbar: each loaded extension's
/// action, plus the way to `cmux://extensions` and the Chrome Web Store.
@available(macOS 15.4, *)
struct BrowserExtensionsToolbarButton: View {
    @ObservedObject var panel: BrowserPanel
    @ObservedObject private var extensions = BrowserExtensions.shared
    let iconPointSize: CGFloat
    let hitSize: CGFloat
    let tint: Color
    let colorScheme: ColorScheme
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            CmuxSystemSymbolImage(systemName: "puzzlepiece.extension", pointSize: iconPointSize, weight: .medium, tint: tint)
                .frame(width: hitSize, height: hitSize, alignment: .center)
        }
        .buttonStyle(OmnibarAddressButtonStyle())
        .frame(width: hitSize, height: hitSize, alignment: .center)
        .background(BrowserExtensionsToolbarAnchor(panelID: panel.id))
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            menu.browserChromePopoverAppearance(colorScheme)
        }
        .safeHelp(String(localized: "browser.extensions.toolbar.help", defaultValue: "Extensions"))
        .accessibilityIdentifier("BrowserExtensionsToolbarButton")
    }

    private var storeOfferID: String? {
        guard let url = panel.currentURL,
              let id = ChromeWebStorePage.extensionID(onStorePage: url),
              !extensions.installed.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    private var menu: some View {
        VStack(alignment: .leading, spacing: 2) {
            let actions = extensions.actionItems(for: panel)
            if actions.isEmpty {
                Text(String(localized: "browser.extensions.page.empty", defaultValue: "No extensions installed."))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
            }
            ForEach(actions) { item in
                row(icon: item.icon, symbol: "puzzlepiece.extension", title: item.name, badge: item.badge) {
                    isPresented = false
                    extensions.performAction(item.id, in: panel)
                }
                .disabled(!item.isEnabled)
            }
            Divider().padding(.vertical, 4)
            if let storeOfferID {
                row(symbol: "plus.circle", title: String(localized: "browser.extensions.store.add", defaultValue: "Add to cmux")) {
                    isPresented = false
                    extensions.installStoreExtension(from: storeOfferID)
                }
                .disabled(extensions.busyID != nil)
            }
            row(symbol: "gearshape", title: String(localized: "browser.extensions.toolbar.manage", defaultValue: "Manage Extensions")) {
                isPresented = false
                extensions.openManagerPage(from: panel)
            }
            row(symbol: "bag", title: String(localized: "browser.extensions.page.openStore", defaultValue: "Open Chrome Web Store")) {
                isPresented = false
                extensions.openStore(from: panel)
            }
            if let error = extensions.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
            }
        }
        .padding(6)
        .frame(width: 280)
    }

    private func row(
        icon: NSImage? = nil,
        symbol: String,
        title: String,
        badge: String = "",
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let icon {
                        Image(nsImage: icon).resizable().interpolation(.high)
                    } else {
                        Image(systemName: symbol).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                if !badge.isEmpty {
                    Text(badge)
                        .font(.system(size: 9, weight: .semibold))
                        .padding(.horizontal, 4)
                        .background(Capsule().fill(Color.secondary.opacity(0.25)))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A real AppKit view under the toolbar button, so an extension's popup
/// popover has something to hang from.
@available(macOS 15.4, *)
private struct BrowserExtensionsToolbarAnchor: NSViewRepresentable {
    let panelID: UUID

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        BrowserExtensions.shared.setAnchor(view, for: panelID)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        BrowserExtensions.shared.setAnchor(view, for: panelID)
    }
}
