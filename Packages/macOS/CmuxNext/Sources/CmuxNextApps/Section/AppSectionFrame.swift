public import CmuxNextDesign
public import SwiftUI
import CmuxNextIcons

/// The frame of an app's sidebar section in each `apps.section.look`
/// prototype: `native` (a plain header with the section glyph, built-in
/// rows), `card` (a subtle inset card with the app icon in the header),
/// `minimal` (title only). The sidebar provider uses it (the App Store is the web page, apps-web-DESIGN.md).
/// In the sidebar the section header row already draws the title (and owns
/// collapse), so the provider passes `showsHeader: false`; drawing both
/// produced a doubled, overlapping title.
public struct AppSectionFrame<Content: View>: View {
    let look: AppSectionLook
    let title: String
    let symbol: String?
    let icon: AppIcon?
    let bundleDirectory: URL?
    let showsHeader: Bool
    let content: Content
    @Environment(\.appSceneColors) private var colors

    public init(look: AppSectionLook, title: String, symbol: String?, icon: AppIcon?, bundleDirectory: URL?,
                showsHeader: Bool = true, @ViewBuilder content: () -> Content) {
        self.look = look
        self.title = title
        self.symbol = symbol
        self.icon = icon
        self.bundleDirectory = bundleDirectory
        self.showsHeader = showsHeader
        self.content = content()
    }

    public var body: some View {
        switch look {
        case .native:
            VStack(alignment: .leading, spacing: Metrics.space1) {
                header { if let symbol { Icon(symbol: symbol, size: 12) } }
                content
            }
        case .minimal:
            VStack(alignment: .leading, spacing: Metrics.space1) {
                header { EmptyView() }
                content
            }
        case .card:
            VStack(alignment: .leading, spacing: Metrics.space1) {
                header { AppIconView(icon: icon, bundleDirectory: bundleDirectory, size: Metrics.smallIconSize + Metrics.space1) }
                content
            }
            .padding(.vertical, Metrics.space2)
            .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius + Metrics.space1, style: .continuous).fill(colors.hover))
            .padding(.horizontal, Metrics.space2)
        }
    }

    @ViewBuilder
    private func header<Leading: View>(@ViewBuilder _ leading: () -> Leading) -> some View {
        if showsHeader { headerRow(leading) }
    }

    private func headerRow<Leading: View>(_ leading: () -> Leading) -> some View {
        HStack(spacing: Metrics.space2) {
            leading()
            Text(title).font(Font(Typography.header))
            Spacer(minLength: 0)
        }
        .foregroundStyle(colors.secondary)
        .padding(.horizontal, Metrics.space3 * 2)
        .frame(height: Metrics.sidebarHeaderHeight)
    }
}
