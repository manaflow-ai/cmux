import CmuxMobileShellModel
import CmuxMobileSupport
import SwiftUI

/// Pager page for a tab the phone cannot stream (a browser or plugin pane
/// open on the Mac). Keeps the workspace's spatial order honest — every tab
/// the Mac shows has a page — while saying plainly what lives there.
struct SurfacePlaceholderPage: View {
    let title: String
    let kind: MobileWorkspacePaneLayout.Tab.Kind

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: kind == .browser ? "globe" : "square.dashed")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(TerminalPalette.dimForeground.opacity(0.7))
            Text(title)
                .font(.headline)
                .foregroundStyle(TerminalPalette.foreground)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            Text(
                kind == .browser
                    ? L10n.string(
                        "mobile.surfaces.browserPlaceholder",
                        defaultValue: "This browser pane is open on your Mac."
                    )
                    : L10n.string(
                        "mobile.surfaces.otherPlaceholder",
                        defaultValue: "This pane is open on your Mac."
                    )
            )
            .font(.footnote)
            .foregroundStyle(TerminalPalette.dimForeground)
            .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(TerminalPalette.background)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("MobileSurfacePlaceholderPage")
    }
}
