#if os(iOS)
import SwiftUI
import UIKit

/// The tabs screen's coordinate space (zoom rects and card frames).
struct TabsScreenSpace {
    static let name = "cmux.tabskit.screen"
    /// `zoomTabId` of a tab being created with (+) before it exists.
    static let newTabMarker = "\u{0}new"
    private init() {}
}

/// Content laid out at the full page size and scaled to this view's width,
/// top aligned and clipped. Cards, the zooming tab and the live page all
/// show the same layout, so a zoom is one rect over one layout.
struct ScaledContent<Content: View>: View {
    var pageSize: CGSize
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { geo in
            let scale = pageSize.width > 0 ? geo.size.width / pageSize.width : 1
            content
                .frame(width: pageSize.width, height: pageSize.height, alignment: .top)
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
        }
        .allowsHitTesting(false)
    }
}

/// One tab card: the card content with rounded corners, close button, title row.
struct TabCard<Content: View>: View {
    var title: String
    var systemImage: String
    var pageSize: CGSize
    var width: CGFloat
    var height: CGFloat
    var radius: CGFloat
    var showsClose: Bool
    var detailsOpacity: Double
    var onClose: () -> Void
    @ViewBuilder var content: Content

    @Environment(\.tabsKitTheme) private var theme

    var body: some View {
        let m = theme.metrics
        VStack(spacing: 0) {
            ScaledContent(pageSize: pageSize) { content }
                .frame(width: width, height: height)
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 3)
                .overlay(alignment: .topTrailing) {
                    if showsClose {
                        Button(action: onClose) {
                            // Measured: 22 pt circle, 4 pt from the card's top and
                            // right edges, a light 9.5 pt cross.
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.colors.cardCloseGlyph)
                                .frame(width: m.cardClose, height: m.cardClose)
                                .background(theme.colors.cardCloseFill, in: .circle)
                                .padding(4)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .opacity(detailsOpacity)
                        .accessibilityLabel("Close \(title)")
                    }
                }
            HStack(spacing: 6) {
                Image(systemName: systemImage).font(.system(size: 14))
                    .foregroundStyle(theme.colors.secondaryLabel)
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.label)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(width: width, height: m.titleRow)
            .padding(.top, 2)
            .opacity(detailsOpacity)
        }
        .frame(width: width, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

/// Tab overview: wallpaper, 2-column grid, top controls and the bottom bar
/// (+, "N Tabs", Done).
struct TabOverview<Source: TabsDataSource>: View {
    var source: Source
    var layout: OverviewLayout
    /// 0 while the page is full screen, 1 with the grid at rest.
    var shown: Double
    var detailsOpacity: Double
    /// Card hidden while the zooming page stands in for it.
    var hiddenTabId: String?
    /// Cards take taps (the grid is settled).
    var gridInteractive: Bool
    /// The bottom bar takes taps (settled, or a zoom heading here: Done reverses it).
    var controlsInteractive: Bool
    @Binding var scrollOffset: CGFloat
    @Binding var position: ScrollPosition
    var onSelect: (String) -> Void
    var onClose: (String) -> Void
    var onNewTab: (TabsKitNewTabOption) -> Void
    var onDone: () -> Void
    var onCloseAll: () -> Void
    /// A tab being created with (+): its card is already in the grid (at
    /// index tabs.count) so the zoom can land on its real frame.
    var pending: TabsKitNewTabOption?
    /// Origin of the grid's scroll content in the screen's coordinate space.
    var onContentOrigin: (CGPoint) -> Void = { _ in }

    @Environment(\.tabsKitTheme) private var theme

    var body: some View {
        let tabs = source.tabs
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: [theme.colors.overviewTop, theme.colors.overviewBottom], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    Color.clear.frame(width: layout.size.width, height: layout.contentHeight)
                    ForEach(Array(tabs.enumerated()), id: \.element.id) { index, tab in
                        let r = layout.card(index)
                        TabCard(title: tab.title, systemImage: tab.systemImage, pageSize: layout.size, width: r.width, height: r.height,
                                radius: layout.cardRadius, showsClose: true, detailsOpacity: detailsOpacity,
                                onClose: { onClose(tab.id) }) {
                            source.card(for: tab)
                        }
                        .opacity(tab.id == hiddenTabId ? 0 : 1)
                        .contentShape(.rect)
                        .onTapGesture { onSelect(tab.id) }
                        .offset(x: r.minX, y: r.minY)
                        .transition(.asymmetric(insertion: .opacity, removal: .opacity.combined(with: .scale(scale: 0.9))))
                    }
                    if let pending {
                        let r = layout.card(tabs.count)
                        TabCard(title: pending.title, systemImage: pending.systemImage, pageSize: layout.size, width: r.width, height: r.height,
                                radius: layout.cardRadius, showsClose: false, detailsOpacity: detailsOpacity, onClose: {}) {
                            theme.colors.pageBackground
                        }
                        .offset(x: r.minX, y: r.minY)
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: layout.size.width, height: layout.contentHeight, alignment: .topLeading)
                .onGeometryChange(for: CGPoint.self, of: { $0.frame(in: .named(TabsScreenSpace.name)).origin }) { onContentOrigin($0) }
            }
            .scrollPosition($position)
            .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y + $0.contentInsets.top }) { _, y in scrollOffset = y }
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .scaleEffect(1.06 - 0.06 * shown)
            .blur(radius: 10 * (1 - shown))
            .allowsHitTesting(gridInteractive)

            // Glass ignores inherited opacity; keep hidden controls out of
            // the hierarchy instead.
            if shown > 0 {
                topControls
                    .opacity(shown)
                    .allowsHitTesting(gridInteractive)
                bottomBar(count: tabs.count)
                    .opacity(shown)
                    .allowsHitTesting(controlsInteractive)
            }
        }
        .frame(width: layout.size.width, height: layout.size.height)
    }

    private var topControls: some View {
        let d = theme.metrics.overviewTopControl
        let y = layout.safeTop + 4 + d / 2
        return ZStack(alignment: .topLeading) {
            Menu {
                Button("Close All Tabs", systemImage: "xmark", role: .destructive, action: onCloseAll)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.colors.label)
                    .frame(width: d, height: d)
                    .contentShape(.circle)
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .position(x: layout.size.width - 20 - d / 2, y: y)
            .accessibilityLabel("More")
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private func bottomBar(count: Int) -> some View {
        let bar = layout.barRect
        let options = source.newTabOptions
        return ZStack(alignment: .topLeading) {
            Group {
                if options.count > 1 {
                    // Several kinds: (+) asks which.
                    Menu {
                        ForEach(options) { option in
                            Button(option.title, systemImage: option.systemImage) { onNewTab(option) }
                        }
                    } label: {
                        plusGlyph
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                } else {
                    Button { if let first = options.first { onNewTab(first) } } label: { plusGlyph }
                        .buttonStyle(.plain)
                        .disabled(options.isEmpty)
                }
            }
            .glassEffect(.regular.interactive(), in: .circle)
            .position(x: 38 + 24, y: bar.midY)
            .accessibilityLabel("New Tab")

            // One glass shape per control (nested glass reads as a double background).
            Text(count == 1 ? "1 Tab" : "\(count) Tabs")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.colors.label)
                .padding(.horizontal, 22)
                .frame(height: 48)
                .glassEffect(.regular, in: .capsule)
                .position(x: layout.size.width / 2, y: bar.midY)
                .contentTransition(.numericText())
                .animation(.default, value: count)

            Button(action: onDone) {
                Image(systemName: "checkmark").font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48).contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.tint(theme.colors.accent).interactive(), in: .circle)
            .position(x: layout.size.width - 38 - 24, y: bar.midY)
            .accessibilityLabel("Done")
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private var plusGlyph: some View {
        Image(systemName: "plus").font(.system(size: 22, weight: .regular))
            .foregroundStyle(theme.colors.label)
            .frame(width: 48, height: 48).contentShape(.circle)
    }
}
#endif
