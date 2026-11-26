#if os(iOS)
import SwiftUI
import UIKit

/// Frames of the three glass shapes for the current chrome state, in screen
/// points.
struct ToolbarLayout {
    var back: CGRect
    var capsule: CGRect
    var right: CGRect

    static func make(metrics m: TabsKitTheme.Metrics, size: CGSize, safeTop: CGFloat = 0, safeBottom: CGFloat, keyboard: CGFloat,
                     bar: ChromeState.Bar, editing: Bool, splitBack: Bool, labelWidth: CGFloat, noBack: Bool = false) -> ToolbarLayout {
        if m.barEdge == .top {
            return makeTop(metrics: m, size: size, safeTop: safeTop, bar: bar, editing: editing, splitBack: splitBack,
                           labelWidth: labelWidth, noBack: noBack)
        }
        let w = size.width
        let bottom = size.height - max(safeBottom, 20)
        let backW = m.control + (splitBack ? m.forwardExtra : 0)
        let barY = bottom - m.control
        let back = CGRect(x: m.sideInset, y: barY, width: backW, height: m.control)
        let tabs = CGRect(x: w - m.sideInset - m.control, y: barY, width: m.control, height: m.control)
        if editing {
            if keyboard > 0 {
                let y = size.height - keyboard - m.editInset - m.control
                let close = CGRect(x: w - m.editInset - m.control, y: y, width: m.control, height: m.control)
                let field = CGRect(x: m.editInset, y: y, width: close.minX - m.gap - m.editInset, height: m.control)
                return ToolbarLayout(back: back.offsetBy(dx: 0, dy: y - barY), capsule: field, right: close)
            }
            let field = CGRect(x: m.sideInset, y: barY, width: tabs.minX - m.gap - m.sideInset, height: m.control)
            return ToolbarLayout(back: back, capsule: field, right: tabs)
        }
        // Tabs without history: the capsule takes the back slot too.
        let capsuleX = noBack ? m.sideInset : back.maxX + m.gap
        let capsule = CGRect(x: capsuleX, y: barY, width: tabs.minX - m.gap - capsuleX, height: m.control)
        if bar == .collapsed {
            // Hugs the label, never wider than the gap between the side controls.
            let pillW = CollapsedPill.width(labelWidth: labelWidth, scale: m.collapsedScale, padding: m.pillPadding,
                                            maxWidth: collapsedMaxWidth(metrics: m, screenWidth: w, backWidth: backW))
            let pill = CGRect(x: (w - pillW) / 2, y: size.height - m.pillBottom - m.pillHeight, width: pillW, height: m.pillHeight)
            // Side circles travel inward with the pill edges while fading.
            let b = CGRect(x: pill.minX - m.gap - back.width, y: pill.midY - m.control / 2, width: back.width, height: m.control)
            let t = CGRect(x: pill.maxX + m.gap, y: pill.midY - m.control / 2, width: m.control, height: m.control)
            return ToolbarLayout(back: b, capsule: pill, right: t)
        }
        return ToolbarLayout(back: back, capsule: capsule, right: tabs)
    }

    /// The bar under the status bar (`barEdge == .top`). It never moves for the keyboard:
    /// Back, the address and Tabs stay one tap away while a composer below is focused.
    /// Editing keeps the field in the bar's row (Safari's top address bar); collapsed, the
    /// pill sits just under the status bar.
    private static func makeTop(metrics m: TabsKitTheme.Metrics, size: CGSize, safeTop: CGFloat, bar: ChromeState.Bar,
                                editing: Bool, splitBack: Bool, labelWidth: CGFloat, noBack: Bool) -> ToolbarLayout {
        let w = size.width
        let inset = m.topSideInset
        let backW = m.control + (splitBack ? m.forwardExtra : 0)
        let barY = topBarY(metrics: m, safeTop: safeTop)
        let back = CGRect(x: inset, y: barY, width: backW, height: m.control)
        let tabs = CGRect(x: w - inset - m.control, y: barY, width: m.control, height: m.control)
        let capsuleX = noBack || editing ? inset : back.maxX + m.gap
        let capsule = CGRect(x: capsuleX, y: barY, width: tabs.minX - m.gap - capsuleX, height: m.control)
        if editing { return ToolbarLayout(back: back, capsule: capsule, right: tabs) }
        if bar == .collapsed {
            let pillW = CollapsedPill.width(labelWidth: labelWidth, scale: m.collapsedScale, padding: m.pillPadding,
                                            maxWidth: collapsedMaxWidth(metrics: m, screenWidth: w, backWidth: backW))
            let pill = CGRect(x: (w - pillW) / 2, y: PageChromeInsets.collapsedTopPillY(safeTop: safeTop, pillHeight: m.pillHeight),
                              width: pillW, height: m.pillHeight)
            let b = CGRect(x: pill.minX - m.gap - back.width, y: pill.midY - m.control / 2, width: back.width, height: m.control)
            let t = CGRect(x: pill.maxX + m.gap, y: pill.midY - m.control / 2, width: m.control, height: m.control)
            return ToolbarLayout(back: b, capsule: pill, right: t)
        }
        return ToolbarLayout(back: back, capsule: capsule, right: tabs)
    }

    /// The top bar's row: just under the status bar (20 pt where a screen reports none).
    static func topBarY(metrics m: TabsKitTheme.Metrics, safeTop: CGFloat) -> CGFloat {
        PageChromeInsets.topBarY(safeTop: safeTop, gap: m.topBarGap)
    }

    /// The page height the bar covers from its edge, gap below it included: the content inset on that edge.
    static func barInset(metrics m: TabsKitTheme.Metrics, size: CGSize, safeTop: CGFloat, safeBottom: CGFloat) -> CGFloat {
        let expanded = make(metrics: m, size: size, safeTop: safeTop, safeBottom: safeBottom, keyboard: 0, bar: .expanded,
                            editing: false, splitBack: false, labelWidth: 69)
        return m.barEdge == .top ? expanded.capsule.maxY + 8 : max(0, size.height - expanded.capsule.minY + 8)
    }

    /// The page's insets under the chrome: `resting` (the expanded bar's, for layout that must
    /// not move while scrolling) and `live` (this frame's, a collapsed top bar's band given back).
    static func pageInsets(metrics m: TabsKitTheme.Metrics, size: CGSize, safeTop: CGFloat, safeBottom: CGFloat,
                           bar: ChromeState.Bar) -> (resting: PageChromeInsets, live: PageChromeInsets) {
        let inset = barInset(metrics: m, size: size, safeTop: safeTop, safeBottom: safeBottom)
        let resting = m.barEdge == .top ? PageChromeInsets(top: inset, bottom: safeBottom)
            : PageChromeInsets(top: safeTop, bottom: inset)
        let live = PageChromeInsets.live(edge: m.barEdge, collapsed: bar == .collapsed, resting: resting, safeTop: safeTop,
                                         pillHeight: m.pillHeight)
        return (resting, live)
    }

    static func collapsedMaxWidth(metrics m: TabsKitTheme.Metrics, screenWidth: CGFloat, backWidth: CGFloat) -> CGFloat {
        CollapsedPill.maxWidth(screenWidth: screenWidth, sideInset: m.sideInset, backWidth: backWidth, control: m.control,
                               gap: m.gap, padding: m.pillPadding)
    }
}

/// Safari's floating bottom toolbar: back circle (split back | forward when
/// there is forward history), address capsule, tabs circle. Collapses to the
/// mini pill, and morphs into the address field while editing.
struct TabsToolbar: View {
    @Bindable var chrome: ChromeState
    var tab: TabsKitTab?
    var size: CGSize
    var safeTop: CGFloat = 0
    var safeBottom: CGFloat
    var keyboard: CGFloat
    /// Long-press menus on back and forward (nil: none).
    var history: ((TabsKitHistoryDirection) -> [TabsKitHistoryItem])?
    var onHistoryItem: (TabsKitHistoryItem) -> Void
    var onBack: () -> Void
    var onForward: () -> Void
    var onReload: () -> Void
    var onMenu: () -> Void
    var onTabs: () -> Void
    var onBeginEditing: () -> Void
    var onEndEditing: () -> Void
    var onGo: (String) -> Void
    var onSwipeChanged: (CGFloat) -> Void
    var onSwipeEnded: (CGFloat, CGFloat) -> Void
    /// Swipe up on the bar (Safari opens the tab grid, following the
    /// finger): the upward translation and velocity in points (/s).
    var onSwipeUpChanged: (CGFloat, CGFloat) -> Void = { _, _ in }
    var onSwipeUpEnded: (CGFloat, CGFloat) -> Void = { _, _ in }
    /// The system cancelled a bar drag on this axis (the app left the
    /// foreground, a system gesture took the touch): no end comes.
    var onSwipeCancelled: (BarSwipe.Axis) -> Void = { _ in }
    /// The paged strip in place of the address capsule (`TabsKitToolbarStyle.pagedTabs`, top
    /// bar only); nil keeps the capsule.
    var strip: ToolbarStrip? = nil

    @State private var labelWidth: CGFloat = 69
    /// The bar drag's direction, fixed once it moved past the slop.
    @State private var swipeAxis: BarSwipe.Axis?
    /// A bar drag moved past the slop: the button under the finger must not
    /// act on touch-up (Safari never opens a menu from a swipe).
    @State private var swipeMoved = false
    /// True while a bar drag is down. A gesture state resets when the drag
    /// ends or is cancelled; only an end calls `onEnded`.
    @GestureState private var swipeDown = false
    @State private var progressShown: CGFloat = 0
    @State private var progressOpacity: Double = 0
    @Environment(\.tabsKitTheme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    static let defaultPlaceholder = "Search or enter website"

    private var showsStrip: Bool { strip != nil && !chrome.editing && theme.metrics.barEdge == .top }
    private var collapsed: Bool { chrome.bar == .collapsed && !chrome.editing }
    /// Over the active page's band the bar takes the band's light or dark, as the status bar
    /// does: a black terminal in light mode reads white chip titles, not black ones.
    private var bandScheme: ColorScheme? {
        guard showsStrip, let color = tab?.pageColor else { return nil }
        // Resolved for the screen's own appearance: `UITraitCollection.current` is not dark while
        // SwiftUI draws, so an adaptive color (the chat's background) read as its light value and
        // turned the bar light in dark mode: the neighbors' titles went black on black.
        let trait = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        return TabsKitStatusBarStyle(over: UIColor(color).resolvedColor(with: trait)) == .lightContent ? .dark : .light
    }
    private var historyState: BackForwardState { BackForwardState(tab: tab, sidesVisible: chrome.sidesVisible, editing: chrome.editing) }
    private var splitBack: Bool { historyState.forwardShown }
    private var address: TabsKitAddress { tab?.address ?? .placeholder(Self.defaultPlaceholder) }
    private var features: TabsKitTabFeatures { tab?.features ?? [.addressEditing] }
    private var isPlaceholder: Bool { if case .placeholder = address { true } else { false } }
    private var titleOnly: (title: String, subtitle: String, monospaced: Bool)? {
        if case .title(let t, let s, let m) = address { (t, s, m) } else { nil }
    }
    private var showsMenuGlyph: Bool { features.contains(.pageMenu) && !isPlaceholder && titleOnly == nil }
    private var showsReload: Bool { features.contains(.reload) && !isPlaceholder && titleOnly == nil }
    private var loading: Bool { tab?.navigation.isLoading == true }

    var body: some View {
        let m = theme.metrics
        let layout = ToolbarLayout.make(metrics: m, size: size, safeTop: safeTop, safeBottom: safeBottom, keyboard: keyboard, bar: chrome.bar,
                                        editing: chrome.editing, splitBack: splitBack, labelWidth: labelWidth,
                                        noBack: !features.contains(.history))
        let sideOpacity: Double = chrome.sidesVisible && !chrome.editing ? 1 : 0
        // Separate glass shapes (no container): a container renders its
        // shapes together and ignores per-shape opacity, which the side
        // circles need for Safari's fade while they slide inward.
        ZStack(alignment: .topLeading) {
            // The whole bar row takes touches, gaps included: a touch between
            // the controls must not reach the page under the toolbar.
            let row = layout.back.union(layout.capsule).union(layout.right)
            Color.clear
                .frame(width: row.width, height: row.height)
                .contentShape(.rect)
                .onTapGesture {}
                .position(x: row.midX, y: row.midY)
                .allowsHitTesting(!collapsed)
                .accessibilityHidden(true)
            if showsStrip, let strip {
                // In the screen's own appearance: New Tab's blank page is the kit's background.
                stripBand(strip, layout: layout)
                    .environment(\.colorScheme, colorScheme)
            }
            if showsStrip, let strip {
                // Its chips fade out at both ends before Back and Tabs.
                // Between Back and Tabs, as Conductor's: a chip is gone by the side buttons' edge.
                let m = theme.metrics
                let frame = CGRect(x: layout.back.maxX + m.gap / 2, y: layout.capsule.minY,
                                   width: layout.right.minX - layout.back.maxX - m.gap, height: layout.capsule.height)
                PagedTabStrip(entries: strip.entries, activeID: strip.activeID, restToken: strip.restToken, frame: frame, screenWidth: size.width,
                              onMove: strip.onMove, onRelease: strip.onRelease, onActiveTap: {
                                  if features.contains(.addressEditing) { onBeginEditing() } else if features.contains(.pageMenu) { onMenu() }
                              })
                    .opacity(chrome.menuOpen ? 0.3 : 1)
                    .position(x: frame.midX, y: frame.midY)
            }
            backButton(layout.back)
                .scaleEffect(collapsed ? 0.8 : 1)
                .opacity(features.contains(.history) ? sideOpacity : 0)
                .position(x: layout.back.midX, y: layout.back.midY)
                .allowsHitTesting(historyState.visible)
                .accessibilityHidden(!historyState.visible)
            if !showsStrip {
                capsule(layout.capsule)
                    .position(x: layout.capsule.midX, y: layout.capsule.midY)
            }
            rightButton(layout.right)
                .scaleEffect(collapsed ? 0.8 : 1)
                .opacity(chrome.editing ? 1 : sideOpacity)
                .position(x: layout.right.midX, y: layout.right.midY)
                .allowsHitTesting(chrome.editing || sideOpacity > 0)
                .accessibilityHidden(!chrome.editing && sideOpacity == 0)
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .environment(\.colorScheme, bandScheme ?? colorScheme)
        .background(alignment: .topLeading) {
            // Width of the label (and its glyph) at 17 pt; the pill hugs it.
            labelContent(m).fixedSize().hidden()
                .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { labelWidth = $0 }
        }
        // Back <-> back | forward and the enabled tint morph with the toolbar spring.
        .animation(theme.motion.resolve(theme.motion.expandTap), value: splitBack)
        .animation(theme.motion.resolve(.easeInOut(duration: 0.2)), value: tab?.navigation.canGoBack == true)
        .onChange(of: loading, initial: true) { _, loading in updateProgress(loading: loading) }
        .onChange(of: tab?.navigation.progress ?? 1) { _, _ in updateProgress(loading: loading) }
    }

    // MARK: Strip band

    /// Conductor's bar sits on the page's own color, which fades out below it (the top scroll
    /// edge effect): the page scrolls under a calm band, never under the chips' text. Each
    /// page's band is its own `TabsKitTab.pageColor` and slides with that page during a strip
    /// swipe, so a terminal's or a chat's background runs up under the bar to the top of the
    /// screen with no seam. A page with no color has no band. New Tab's blank page is the
    /// kit's page background.
    private func stripBand(_ strip: ToolbarStrip, layout: ToolbarLayout) -> some View {
        let bottom = layout.capsule.maxY + 14
        let active = strip.entries.firstIndex { $0.id == strip.activeID } ?? 0
        let offset = chrome.swiping ? chrome.swipeOffset : 0
        let pages = strip.entries.enumerated().compactMap { index, entry -> (id: String, x: CGFloat, color: Color)? in
            let x = CGFloat(index - active) * size.width + offset
            let color: Color? = switch entry {
            case .tab(let tab): tab.pageColor
            case .newTab: theme.colors.pageBackground
            }
            guard abs(x) < size.width, let color else { return nil }
            return (entry.id, x, color)
        }
        return ZStack(alignment: .topLeading) {
            ForEach(pages, id: \.id) { page in
                page.color
                    .frame(width: size.width, height: bottom)
                    .offset(x: page.x)
            }
        }
        .frame(width: size.width, height: bottom, alignment: .topLeading)
        .clipped()
        .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                     .init(color: .black, location: (layout.capsule.maxY - 6) / bottom),
                                     .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    // MARK: Back / forward

    /// One glass capsule whose width animates between the 48 pt back circle
    /// and the back | forward capsule; the forward glyph slides and fades
    /// inside it, and the disabled tint crossfades, all on the toolbar spring.
    @ViewBuilder private func backButton(_ r: CGRect) -> some View {
        let canBack = historyState.backEnabled
        let control = theme.metrics.control
        let half = splitBack ? r.width / 2 : control
        ZStack(alignment: .leading) {
            historyControl(.back, action: onBack) {
                Image(systemName: "chevron.left").font(.system(size: 19, weight: .medium))
                    .frame(width: half, height: r.height)
                    .contentShape(.rect)
            }
            .disabled(!canBack)
            .foregroundStyle(canBack ? theme.colors.label : theme.colors.glyphDisabled)
            .frame(width: half, height: r.height)
            .accessibilityLabel("Back")
            if splitBack {
                // Laid out (not offset) beside the back half, so its hit
                // area is exactly the forward half.
                // The forward glyph is this control's label, inserted and
                // removed with the capsule's animation (fades in sliding out
                // of the back circle's center); a separate transparent glyph
                // stayed in the accessibility tree as a stray "Forward".
                HStack(spacing: 0) {
                    Spacer(minLength: 0).frame(width: half)
                    historyControl(.forward, action: onForward) {
                        Image(systemName: "chevron.right").font(.system(size: 19, weight: .medium))
                            .foregroundStyle(theme.colors.label)
                            .frame(width: max(1, r.width - half), height: r.height)
                            .contentShape(.rect)
                    }
                    .accessibilityLabel("Forward")
                }
                .transition(.opacity.combined(with: .offset(x: control / 2 - r.width / 2)))
            }
        }
        .buttonStyle(.plain)
        .opacity(chrome.menuOpen ? 0.3 : 1)
        .frame(width: r.width, height: r.height, alignment: .leading)
        .accessibilityElement(children: .contain)
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
    }

    /// A back or forward button; with history menus, a menu whose tap is
    /// the step and whose long press lists the history.
    @ViewBuilder private func historyControl<Label: View>(_ direction: TabsKitHistoryDirection, action: @escaping () -> Void,
                                                         @ViewBuilder label: () -> Label) -> some View {
        if let history {
            Menu {
                ForEach(history(direction)) { item in
                    Button { onHistoryItem(item) } label: {
                        Text(item.title)
                        if !item.subtitle.isEmpty { Text(item.subtitle) }
                    }
                }
            } label: {
                label()
            } primaryAction: {
                action()
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
        } else {
            Button(action: action, label: label)
        }
    }

    // MARK: Tabs / close

    @ViewBuilder private func rightButton(_ r: CGRect) -> some View {
        Button {
            if chrome.editing { onEndEditing() } else { onTabs() }
        } label: {
            ZStack {
                // One glyph at a time, cross-faded by the transition.
                if chrome.editing {
                    Image(systemName: "xmark").font(.system(size: 19, weight: .regular))
                        .transition(.opacity)
                } else {
                    Image(systemName: "square.on.square").font(.system(size: 22.2, weight: .regular))
                        .transition(.opacity)
                }
            }
            .foregroundStyle(theme.colors.label)
            .opacity(chrome.menuOpen ? 0.3 : 1)
            .frame(width: r.width, height: r.height)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .frame(width: r.width, height: r.height)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(chrome.editing ? "Cancel" : "Tabs")
    }

    // MARK: Capsule

    @ViewBuilder private func capsule(_ r: CGRect) -> some View {
        let m = theme.metrics
        let glyphOpacity: Double = (collapsed || chrome.editing ? 0 : 1) * (chrome.menuOpen ? 0.3 : 1)
        ZStack {
            // Leading page-menu slot (48 pt).
            Button(action: unlessSwiped(onMenu)) {
                PageMenuGlyph()
                    .fill(theme.colors.label)
                    .frame(width: 16.3, height: 12.3)
                    .offset(x: 0.7)
                    .frame(width: m.control, height: m.control)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .opacity(showsMenuGlyph ? glyphOpacity : 0)
            .allowsHitTesting(!collapsed && !chrome.editing && showsMenuGlyph)
            .accessibilityHidden(collapsed || chrome.editing || !showsMenuGlyph)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel("Page Menu")

            if let t = titleOnly {
                titleLabel(t, r)
            } else if !chrome.editing {
                label(r)
            } else {
                AddressField(text: $chrome.editText, placeholder: isPlaceholder ? address.label : Self.defaultPlaceholder, onGo: onGo)
                    .padding(.leading, 12)
                    .padding(.trailing, 44)
                    .frame(width: r.width, height: r.height)
                    .transition(.opacity)
                if !chrome.editText.isEmpty {
                    Button { chrome.editText = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 17))
                            .foregroundStyle(theme.colors.label)
                            .frame(width: 44, height: 48).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .accessibilityLabel("Clear text")
                }
            }

            // Trailing reload / stop.
            Button(action: unlessSwiped(onReload)) {
                ZStack {
                    if loading {
                        Image(systemName: "xmark").transition(.opacity)
                    } else {
                        Image(systemName: "arrow.clockwise").transition(.opacity)
                    }
                }
                .offset(y: -1)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 44, height: m.control)
                .contentShape(.rect)
                .animation(theme.motion.resolve(.easeInOut(duration: 0.15)), value: loading)
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.colors.label)
            .opacity(showsReload ? glyphOpacity : 0)
            .allowsHitTesting(!collapsed && !chrome.editing && showsReload)
            .accessibilityHidden(collapsed || chrome.editing || !showsReload)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityLabel(loading ? "Stop" : "Reload")
        }
        .frame(width: r.width, height: r.height)
        .overlay(alignment: .bottomLeading) {
            Rectangle().fill(theme.colors.accent)
                .frame(width: r.width * progressShown, height: m.progressHeight)
                .opacity(chrome.editing ? 0 : progressOpacity)
        }
        .clipShape(.capsule)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentShape(.capsule)
        .simultaneousGesture(swipe, including: chrome.editing || collapsed ? .subviews : .all)
        .onChange(of: swipeDown) { _, down in
            guard !down else { return }
            // After `onEnded` of the same touch-up, which clears the axis.
            Task { @MainActor in
                guard let axis = swipeAxis else { return }
                swipeAxis = nil
                swipeMoved = false
                onSwipeCancelled(axis)
            }
        }
        .overlay {
            // Collapsed: the whole pill is one hit target that starts the
            // expand spring on touch-up. A zero-distance drag ends on
            // touch-up without waiting for another gesture to fail.
            if collapsed {
                Capsule().fill(Color.clear)
                    .contentShape(.capsule)
                    .highPriorityGesture(DragGesture(minimumDistance: 0, coordinateSpace: .local).onEnded { _ in
                        chrome.expand(tap: true, theme)
                    })
                    .accessibilityElement()
                    .accessibilityLabel("Show toolbar, \(address.label)")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { chrome.expand(tap: true, theme) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// Title over a subtitle (a terminal's `host ~/cwd`); collapses to the title.
    @ViewBuilder private func titleLabel(_ t: (title: String, subtitle: String, monospaced: Bool), _ r: CGRect) -> some View {
        Button(action: unlessSwiped {
            if collapsed { chrome.expand(tap: true, theme) } else if features.contains(.pageMenu) { onMenu() }
        }) {
            VStack(spacing: 0) {
                Text(t.title)
                    .font(.system(size: collapsed ? 13 : 15, weight: .semibold))
                    .lineLimit(1)
                if !collapsed, !t.subtitle.isEmpty {
                    Text(t.subtitle)
                        .font(t.monospaced ? .system(size: 11).monospaced() : .system(size: 11))
                        .foregroundStyle(theme.colors.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .foregroundStyle(theme.colors.label)
            // Collapsed, a title capped by the pill keeps 12 pt clear of its ends.
            .frame(width: max(0, r.width - (collapsed ? 24 : 2 * theme.metrics.control)), height: r.height)
            .contentShape(.rect)
        }
        .buttonStyle(GlassContentButtonStyle())
        .accessibilityLabel(t.subtitle.isEmpty ? t.title : "\(t.title), \(t.subtitle)")
    }

    /// The address label: a glyph (search, file) and one truncating line.
    @ViewBuilder private func labelContent(_ m: TabsKitTheme.Metrics) -> some View {
        let isSearch: Bool = if case .url(_, _, let s) = address { s } else { false }
        HStack(spacing: 5) {
            if isPlaceholder || isSearch {
                Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
            } else if address.isFile {
                Image(systemName: "doc").font(.system(size: 14, weight: .medium))
            }
            Text(address.label)
                .font(.system(size: m.urlFont, weight: isPlaceholder ? .regular : .medium))
                .lineLimit(1)
                // A file name keeps its extension; a host keeps its start.
                .truncationMode(address.isFile ? .middle : .tail)
        }
    }

    @ViewBuilder private func label(_ r: CGRect) -> some View {
        let m = theme.metrics
        // A placeholder has no menu glyph, so it may use the leading slot.
        let maxW = max(40, r.width - (isPlaceholder ? m.control + 24 : 2 * m.control + 8))
        // Collapsed, the label is drawn at 17 pt and scaled down: its unscaled
        // width is the measured one, capped by the pill.
        // One point over the measured width, so rounding never adds an ellipsis to a label that fits.
        let collapsedW = CollapsedPill.labelWidth(
            labelWidth: labelWidth + 1, scale: m.collapsedScale, padding: m.pillPadding,
            maxWidth: ToolbarLayout.collapsedMaxWidth(metrics: m, screenWidth: size.width,
                                                      backWidth: m.control + (splitBack ? m.forwardExtra : 0)))
        Button(action: unlessSwiped {
            if collapsed {
                chrome.expand(tap: true, theme)
            } else if features.contains(.addressEditing) {
                onBeginEditing()
            } else if features.contains(.pageMenu) {
                onMenu()
            }
        }) {
            labelContent(m)
            .foregroundStyle(isPlaceholder ? theme.colors.secondaryLabel : theme.colors.label)
            .frame(width: collapsed ? collapsedW : nil)
            .frame(maxWidth: collapsed ? nil : maxW)
            // The label rides with its page during a toolbar swipe.
            .offset(x: chrome.swiping ? chrome.swipeOffset : 0)
            .opacity(chrome.swiping ? 1 - min(1, abs(chrome.swipeOffset) / (size.width * 0.5)) : 1)
            .fixedSize(horizontal: collapsed, vertical: false)
            .scaleEffect(collapsed ? m.collapsedScale : 1)
            // Expanded, the label owns only the middle; the 48 pt slots at
            // either end belong to the menu and reload buttons.
            .frame(width: collapsed ? r.width : max(0, r.width - (isPlaceholder ? m.control : 2 * m.control)), height: r.height)
            .contentShape(.rect)
        }
        .buttonStyle(GlassContentButtonStyle())
        .accessibilityLabel(collapsed ? "Show toolbar, \(address.label)" : "Address, \(address.label)")
    }

    /// A button action that does nothing when the touch was a bar swipe.
    private func unlessSwiped(_ action: @escaping () -> Void) -> () -> Void {
        {
            if swipeMoved { swipeMoved = false } else { action() }
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .updating($swipeDown) { _, down, _ in down = true }
            .onChanged { v in
                guard !chrome.editing, !collapsed else { return }
                swipeMoved = true
                let axis = swipeAxis ?? BarSwipe.axis(v.translation)
                if swipeAxis == nil { swipeAxis = axis }
                switch axis {
                case .horizontal: onSwipeChanged(v.translation.width)
                // Away from the bar's edge into the page opens the grid: up from a bottom bar, down from a top one.
                case towardPage: onSwipeUpChanged(gridTravel(v.translation.height), gridTravel(v.velocity.height))
                default: break
                }
            }
            .onEnded { v in
                let axis = swipeAxis
                swipeAxis = nil
                // After the button under the finger saw this touch-up.
                Task { @MainActor in swipeMoved = false }
                if axis == .horizontal {
                    if chrome.swiping { onSwipeEnded(v.translation.width, v.predictedEndTranslation.width) }
                } else if axis == towardPage {
                    onSwipeUpEnded(gridTravel(v.translation.height), gridTravel(v.velocity.height))
                }
            }
    }

    /// The bar drag that opens the grid: into the page, away from the bar's edge.
    private var towardPage: BarSwipe.Axis { theme.metrics.barEdge == .top ? .down : .up }

    /// A vertical drag as travel into the page (positive), from either edge.
    private func gridTravel(_ dy: CGFloat) -> CGFloat { theme.metrics.barEdge == .top ? dy : -dy }

    // MARK: Progress

    private func updateProgress(loading: Bool) {
        if loading {
            let p = max(0.03, CGFloat(tab?.navigation.progress ?? 0))
            if progressOpacity == 0 {
                progressShown = 0
                progressOpacity = 1
                withAnimation(theme.motion.resolve(.easeOut(duration: 0.25))) { progressShown = p }
            } else {
                withAnimation(theme.motion.resolve(.easeOut(duration: 0.25))) { progressShown = max(progressShown, p) }
            }
        } else if progressOpacity > 0 {
            withAnimation(theme.motion.resolve(.easeOut(duration: 0.2))) { progressShown = 1 } completion: {
                withAnimation(theme.motion.resolve(.easeOut(duration: 0.25))) { progressOpacity = 0 }
            }
        }
    }
}

/// What the toolbar's paged strip shows and reports (`PagedTabStrip`).
struct ToolbarStrip {
    var entries: [StripEntry]
    var activeID: String?
    /// Bumped to send the strip back to the active chip (a New Tab that failed).
    var restToken: Int
    var onMove: (CGFloat) -> Void
    var onRelease: (Int) -> Void
}

/// Glass buttons highlight through the interactive glass itself; the
/// label must not dim on press (it would flash during the pill expand).
struct GlassContentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}

/// Safari's page-menu glyph: three left-aligned rounded lines, the last
/// one shorter (16.3 x 12.3 pt, 1.8 pt strokes).
struct PageMenuGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let t: CGFloat = 1.8
        let pitch = (rect.height - t) / 2
        var p = Path()
        for (i, frac) in [1.0, 1.0, 0.675].enumerated() {
            p.addRoundedRect(in: CGRect(x: rect.minX, y: rect.minY + CGFloat(i) * pitch, width: rect.width * frac, height: t),
                             cornerSize: CGSize(width: t / 2, height: t / 2))
        }
        return p
    }
}

/// The address field: full text selected on focus, Go key navigates.
struct AddressField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onGo: (String) -> Void

    func makeUIView(context: Context) -> UITextField {
        let f = UITextField()
        f.font = .systemFont(ofSize: 17)
        f.keyboardType = .webSearch
        f.returnKeyType = .go
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.clearButtonMode = .never
        f.textContentType = .URL
        f.placeholder = placeholder
        f.delegate = context.coordinator
        f.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .editingChanged)
        f.text = text
        f.setContentHuggingPriority(.defaultLow, for: .horizontal)
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // justification: becomeFirstResponder needs the field in its window,
        // which happens after makeUIView returns (next main-queue turn).
        DispatchQueue.main.async {
            f.becomeFirstResponder()
            f.selectAll(nil)
        }
        return f
    }

    func updateUIView(_ f: UITextField, context: Context) {
        context.coordinator.parent = self
        // Only push external changes (the clear button); echoing our own
        // edits back can drop keystrokes that arrived in between.
        if text != context.coordinator.lastEmitted, f.text != text {
            f.text = text
            context.coordinator.lastEmitted = text
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, UITextFieldDelegate {
        var parent: AddressField
        var lastEmitted: String
        init(parent: AddressField) { self.parent = parent; lastEmitted = parent.text }

        @objc func changed(_ f: UITextField) {
            lastEmitted = f.text ?? ""
            parent.text = lastEmitted
        }

        func textFieldShouldReturn(_ f: UITextField) -> Bool {
            parent.onGo(f.text ?? "")
            return false
        }
    }
}
#endif
