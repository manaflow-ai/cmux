public import CmuxNextDesign
public import SwiftUI

/// The frame of an app's sidebar section in each `apps.section.look`
/// prototype: `native` (a plain header with the section glyph, built-in
/// rows), `card` (a subtle inset card with the app icon in the header),
/// `minimal` (title only). The sidebar provider and store previews share it.
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
                header { if let symbol { Image(systemName: symbol).font(.system(size: Metrics.smallIconSize - Metrics.space2)) } }
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

/// A status item as it sits in the titlebar: compact, on the chrome.
struct AppStatusItemFrame<Content: View>: View {
    let content: Content
    @Environment(\.appSceneColors) private var colors

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        HStack(spacing: 0) { content }
            .frame(height: Metrics.titlebarHeight - Metrics.space3)
            .padding(.horizontal, Metrics.space2)
            .background(RoundedRectangle(cornerRadius: Metrics.itemCornerRadius, style: .continuous).fill(colors.elevated))
            .fixedSize()
    }
}
