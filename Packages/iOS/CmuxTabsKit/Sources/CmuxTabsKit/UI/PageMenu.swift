#if os(iOS)
import SwiftUI

/// The page menu: one glass panel, 250 pt wide, left-aligned with the
/// capsule, that grows out of the menu button like a droplet.
struct PageMenu: View {
    var groups: [[TabsKitMenuItem]]
    /// The menu button frame (start of the morph) and the capsule frame.
    var origin: CGRect
    var capsule: CGRect
    var topLimit: CGFloat
    var expanded: Bool
    /// Content fades in over 80-200 ms and unblurs, on its own clock.
    var contentVisible: Bool
    var onDismiss: () -> Void
    var onSelect: (TabsKitMenuItem) -> Void

    @Environment(\.tabsKitTheme) private var theme
    @State private var measured: CGFloat?

    private var contentHeight: CGFloat {
        if let measured { return measured }
        let m = theme.metrics
        let rows = CGFloat(groups.reduce(0) { $0 + $1.count })
        return rows * m.menuRow + CGFloat(max(0, groups.count - 1)) * m.menuGroupGap + 20
    }

    var body: some View {
        let m = theme.metrics
        let bottom = capsule.maxY - 1
        let height = max(1, min(contentHeight, bottom - topLimit))
        let full = CGRect(x: capsule.minX, y: bottom - height, width: m.menuWidth, height: height)
        let r = expanded ? full : origin
        ZStack(alignment: .topLeading) {
            Color.clear
                .contentShape(.rect)
                .onTapGesture(perform: onDismiss)
                .accessibilityHidden(true)
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { index, group in
                        if index > 0 {
                            Rectangle().fill(theme.colors.separator)
                                .frame(height: 0.5)
                                .padding(.leading, 27).padding(.trailing, 10)
                                .frame(height: m.menuGroupGap)
                        }
                        ForEach(group) { item in row(item) }
                    }
                }
                .padding(.vertical, 10)
                .frame(width: m.menuWidth, alignment: .leading)
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { measured = $0 }
            }
            .scrollDisabled(contentHeight <= height)
            .scrollBounceBehavior(.basedOnSize)
            .frame(width: m.menuWidth, height: height, alignment: .top)
            .opacity(contentVisible ? 1 : 0)
            .blur(radius: contentVisible ? 0 : 8)
            // The rows scale with the droplet (they are lensed, not clipped).
            .scaleEffect(x: r.width / full.width, y: r.height / full.height, anchor: .topLeading)
            .frame(width: r.width, height: r.height, alignment: .topLeading)
            .clipShape(DropletShape(progress: expanded ? 1 : 0, finalRadius: m.menuRadius))
            .glassEffect(.regular.interactive(), in: DropletShape(progress: expanded ? 1 : 0, finalRadius: m.menuRadius))
            .offset(x: r.minX, y: r.minY)
        }
    }

    @ViewBuilder private func row(_ item: TabsKitMenuItem) -> some View {
        let m = theme.metrics
        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 0) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 18))
                    .frame(width: 30)
                    .padding(.leading, 25)
                Text(item.title)
                    .font(.system(size: 17))
                    .padding(.leading, 10)
                    .lineLimit(2)
                Spacer(minLength: 12)
            }
            .foregroundStyle(!item.isEnabled ? theme.colors.glyphDisabled : (item.isDestructive ? Color.red : theme.colors.label))
            .padding(.vertical, 10)
            .frame(width: m.menuWidth, alignment: .leading)
            .frame(minHeight: m.menuRow)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!item.isEnabled)
    }
}

/// Rounded rect that stays a capsule (radius = half the short side) while
/// the droplet grows and only settles to the panel radius near the end.
struct DropletShape: Shape {
    var progress: CGFloat
    var finalRadius: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let capsule = min(rect.width, rect.height) / 2
        let t = max(0, min(1, (progress - 0.6) / 0.4))
        let radius = capsule + (min(finalRadius, capsule) - capsule) * t * t * (3 - 2 * t)
        return Path(roundedRect: rect, cornerRadius: radius, style: .continuous)
    }
}
#endif
