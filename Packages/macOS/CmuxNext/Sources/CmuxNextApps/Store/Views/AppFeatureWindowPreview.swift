import CmuxNextDesign
import CmuxNextIcons
import SwiftUI

/// A small cmux window in placeholder shapes with the part a feature changes lit and its icon
/// placed there, so a card shows where the feature lives instead of a lone icon.
struct AppFeatureWindowPreview: View {
    let area: AppFeature.Area
    let icon: IconName
    @Environment(\.appSceneColors) private var colors

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if area == .background {
                lit(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Icon(icon, size: 16).foregroundStyle(colors.primary).padding(Metrics.space2)
            }
            window
                .padding(EdgeInsets(top: Metrics.space4, leading: Metrics.space4, bottom: area == .background ? Metrics.space4 : 0,
                                    trailing: area == .background ? 28 : Metrics.space4))
        }
    }

    private var window: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: area == .background ? 6 : 0,
                                           bottomTrailingRadius: area == .background ? 6 : 0, topTrailingRadius: 6, style: .continuous)
        return HStack(spacing: 0) {
            sidebar.frame(width: 64)
            Rectangle().fill(colors.separator).frame(width: 0.5)
            VStack(spacing: 0) {
                tabBar
                content
            }
        }
        .background(colors.background.opacity(area == .background ? 0.82 : 1))
        .clipShape(shape)
        .overlay(shape.strokeBorder(colors.separator, lineWidth: 0.5))
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            if area == .sidebarItem {
                row(icon: icon, width: 0.6).background(litShape(radius: 3))
            }
            row(icon: nil, width: 0.7, selected: area != .sidebarItem)
            row(icon: nil, width: 0.5)
            row(icon: nil, width: 0.62)
            if area != .sidebarItem { row(icon: nil, width: 0.44) }
            Spacer(minLength: 0)
            if area == .sidebarBottom {
                row(icon: icon, width: 0.55).background(litShape(radius: 3))
            }
        }
        .padding(Metrics.space2)
        .frame(maxHeight: .infinity, alignment: .top)
        .background { if area == .sidebar { lit(Rectangle()) } }
        .overlay(alignment: .topTrailing) {
            if area == .sidebar { Icon(icon, size: 12).foregroundStyle(colors.primary).padding(Metrics.space1) }
        }
    }

    private func row(icon: IconName?, width: CGFloat, selected: Bool = false) -> some View {
        HStack(spacing: Metrics.space1) {
            if let icon {
                Icon(icon, size: 9).foregroundStyle(colors.primary)
            } else {
                Circle().fill(colors.tertiary).frame(width: 4, height: 4)
            }
            GeometryReader { proxy in
                bar(icon == nil ? colors.tertiary : colors.secondary, width: proxy.size.width * width)
                    .frame(maxHeight: .infinity)
            }
        }
        .frame(height: 11)
        .padding(.horizontal, Metrics.space1)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(selected ? colors.selection : .clear))
    }

    // MARK: Tabs and content

    private var tabBar: some View {
        HStack(spacing: Metrics.space1) {
            tab(icon: area == .tabBar ? icon : nil, selected: true)
            tab(icon: nil, selected: false)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Metrics.space2)
        .frame(height: 14)
        .background { if area == .tabBar { lit(Rectangle()) } }
    }

    private func tab(icon: IconName?, selected: Bool) -> some View {
        HStack(spacing: Metrics.space1) {
            if let icon { Icon(icon, size: 8).foregroundStyle(colors.primary) }
            bar(selected ? colors.secondary : colors.tertiary, width: 18)
        }
        .padding(.horizontal, Metrics.space1)
        .frame(height: 10)
        .background(RoundedRectangle(cornerRadius: 3, style: .continuous).fill(selected ? colors.selection : .clear))
    }

    @ViewBuilder private var content: some View {
        switch area {
        case .newTab: newTabPage
        case .browser: browserPage
        case .panes: HStack(spacing: Metrics.space1) { litPane(withIcon: true); litPane(withIcon: false) }.padding(Metrics.space1)
        case .pane: litPane(withIcon: true).padding(Metrics.space1)
        case .background, .sidebar, .sidebarItem, .sidebarBottom, .tabBar: lines
        }
    }

    private var lines: some View {
        textLines.padding(Metrics.space2)
    }

    private var textLines: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            ForEach(Array(([0.7, 0.45, 0.6, 0.35] as [CGFloat]).enumerated()), id: \.offset) { _, width in
                GeometryReader { proxy in bar(colors.tertiary, width: proxy.size.width * width) }.frame(height: 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func litPane(withIcon: Bool) -> some View {
        ZStack {
            lit(RoundedRectangle(cornerRadius: 4, style: .continuous))
            if withIcon { Icon(icon, size: 16).foregroundStyle(colors.primary) }
        }
    }

    private var newTabPage: some View {
        VStack(spacing: Metrics.space1) {
            bar(colors.tertiary, width: 40).padding(.bottom, Metrics.space1)
            HStack(spacing: Metrics.space1) {
                ZStack {
                    lit(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    Icon(icon, size: 12).foregroundStyle(colors.primary)
                }
                widget
            }
            HStack(spacing: Metrics.space1) { widget; widget }
        }
        .padding(EdgeInsets(top: Metrics.space2, leading: Metrics.space4, bottom: Metrics.space2, trailing: Metrics.space4))
    }

    private var widget: some View {
        RoundedRectangle(cornerRadius: 3, style: .continuous).fill(colors.hover)
    }

    private var browserPage: some View {
        VStack(alignment: .leading, spacing: Metrics.space1) {
            HStack(spacing: Metrics.space1) {
                Icon(icon, size: 9).foregroundStyle(colors.primary)
                bar(colors.secondary, width: 44)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Metrics.space1)
            .frame(height: 12)
            .background(litShape(radius: 3))
            textLines.padding(.top, Metrics.space1)
        }
        .padding(Metrics.space2)
    }

    // MARK: Pieces

    private func bar(_ color: Color, width: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: max(width, 0), height: 4)
    }

    /// The part the feature changes: a raised fill with a stronger edge.
    private func lit(_ shape: some InsettableShape) -> some View {
        shape.fill(colors.elevated).overlay(shape.strokeBorder(colors.secondary.opacity(0.6), lineWidth: 1))
    }

    private func litShape(radius: CGFloat) -> some View {
        lit(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}
