import AppKit
import CmuxNextCompat
import CmuxNextDesign
import CmuxNextIcons
import QuartzCore

/// The strip's edge fades: a gradient mask on the tabs' clip, shown only while tabs are hidden beyond
/// an edge. The strip holds one and calls `update` after each frame application.
@MainActor final class TabEdgeFade {
    private weak var strip: TabStripView?
    let mask = CAGradientLayer()
    /// Edges whose fade is shown or fading in (`update`).
    private(set) var edges: (leading: Bool, trailing: Bool) = (false, false)

    init(strip: TabStripView) {
        self.strip = strip
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.actions = ["bounds": NSNull(), "position": NSNull(), "colors": NSNull(), "locations": NSNull()]
    }

    /// Fades the strip's ends only while tabs are hidden beyond them: none
    /// on the leading edge at offset 0, none on the trailing edge at the
    /// end, none when every tab fits (rubber band past an end included). An
    /// edge's band fades in or out with the Motion `hover` token (a short
    /// crossfade under Reduce Motion, per the Motion policy); the mask comes off once no edge is faded, so a
    /// strip that fits renders with no offscreen pass.
    func update() {
        guard let strip else { return }
        let fadeMask = mask, tabsClip = strip.tabsClip
        let width = strip.viewportWidth
        let edges = width > 0
            ? TabScrollMath.fadedEdges(offset: strip.scrollOffset, contentWidth: strip.result.contentWidth, viewportWidth: width)
            : (leading: false, trailing: false)
        // The leading fade starts after the fixed pinned band, which never fades.
        let band = min(strip.scrollMapping.band, width)
        let fade = min(strip.metrics.scrollFadeWidth, max(0, width - band) / 2) / max(width, 1)
        let start = band / max(width, 1)
        fadeMask.frame = tabsClip.bounds
        fadeMask.locations = [0, start, start, start + fade, 1 - fade, 1].map { NSNumber(value: Double($0)) }
        guard edges != self.edges else { return }
        let wasFaded = self.edges.leading || self.edges.trailing
        let isFaded = edges.leading || edges.trailing
        self.edges = edges
        let opaque = NSColor.black.cgColor
        let clear = NSColor.clear.cgColor
        let colors = [opaque, opaque, edges.leading ? clear : opaque, opaque, opaque, edges.trailing ? clear : opaque]
        if isFaded, tabsClip.layer?.mask !== fadeMask { tabsClip.layer?.mask = fadeMask }
        let animates = strip.window != nil && (wasFaded || isFaded) && !Motion.isLiveResizing(strip.window) // in a live resize of its window the edge follows at once
        CATransaction.begin()
        CATransaction.setMainCompletion { [weak self] in
            guard let self, let strip = self.strip, !(self.edges.leading || self.edges.trailing) else { return }
            if strip.tabsClip.layer?.mask != nil { strip.tabsClip.layer?.mask = nil }
        }
        if animates {
            // A freshly installed mask starts from fully opaque, not from
            // the colors it had when it came off.
            Motion.tabs.set(fadeMask, "colors", to: colors, fade: .hover, from: wasFaded ? nil : Array(repeating: opaque, count: colors.count))
        } else {
            fadeMask.removeAnimation(forKey: "colors")
            Motion.tabs.transaction(nil) { fadeMask.colors = colors }
        }
        CATransaction.commit()
    }
}

/// Settings > Experimental `experiments.tabOverflow`: the strip's overflow controls, made on first use and hidden
/// under `off`. `chevrons`: a chevron over each faded edge, appearing and going with its fade, pages the strip;
/// `moreMenu`: a More pill after the last visible tab lists the tabs that left the row; `allTabs`: an All Tabs pill
/// held at the strip's trailing end while the tabs overflow lists every tab. The menus are built when they open.
/// The strip places them after each frame application (``update(runEnd:tabY:tabHeight:)``).
@MainActor final class TabOverflowControls: NSObject {
    private weak var strip: TabStripView?
    private var leadingChevron: TitlebarBandButton?
    private var trailingChevron: TitlebarBandButton?
    /// The More or All Tabs pill, as ``pillMode`` made it.
    private var pill: TitlebarBandButton?
    private var pillMode: TabOverflowExperiment = .off
    /// The pill's width for ``pillMode``, measured once per mode and token change.
    private var pillWidthCache: CGFloat?
    /// The chevrons shown (or fading in), leading and trailing.
    private(set) var chevrons: (leading: Bool, trailing: Bool) = (false, false)
    /// `allTabs`: the strip keeps the pill's room after the tabs because they overflow (`TabStripView.layout`).
    var reservesAllTabs = false

    init(strip: TabStripView) {
        self.strip = strip
    }

    private var experiment: TabOverflowExperiment { strip?.metrics.overflowExperiment ?? .off }

    /// The pill's width for the current arm (0 without one): the More pill's room in the partition, the All Tabs
    /// pill's in the strip's viewport.
    var pillWidth: CGFloat {
        guard experiment == .moreMenu || experiment == .allTabs else { return 0 }
        if pillMode == experiment, let pillWidthCache { return pillWidthCache }
        let width = makePill().preferredWidth
        pillWidthCache = width
        return width
    }

    /// Whether the pill shows now: More while tabs wait in it, All Tabs while its room is kept.
    var showsPill: Bool {
        switch experiment {
        case .moreMenu: !(strip?.overflowPartition.hidden.isEmpty ?? true)
        case .allTabs: reservesAllTabs
        case .off, .chevrons: false
        }
    }

    /// The room the shown pill takes between the tabs and the + (0 when none shows).
    var trailingWidth: CGFloat { showsPill ? pillWidth : 0 }

    /// Density or font changed: the pill measures again.
    func tokensChanged() {
        pillWidthCache = nil
        pill?.needsLayout = true
    }

    /// Places and shows the controls for the strip as just framed. `runEnd`: the tabs' trailing edge in the strip's
    /// content view, clipped to the viewport (where the + follows them).
    func update(runEnd: CGFloat, tabY: CGFloat, tabHeight: CGFloat) {
        guard let strip else { return }
        let mode = experiment
        let side = TitlebarBandButton.side
        let scale = strip.window?.backingScaleFactor ?? 2
        func pixel(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let y = pixel(tabY + (tabHeight - side) / 2)
        // Chevrons: over the faded edges, never wider than a fade, so the revealed tab (a fade's width from the edge)
        // is never under one.
        let edges = mode == .chevrons ? strip.edgeFade.edges : (leading: false, trailing: false)
        if mode == .chevrons || leadingChevron != nil {
            let clip = strip.tabsClip.frame
            let width = min(side, strip.metrics.scrollFadeWidth)
            let band = min(strip.scrollMapping.band, clip.width)
            let leading = leadingChevron ?? makeChevron(leading: true)
            let trailing = trailingChevron ?? makeChevron(leading: false)
            leading.frame = CGRect(x: pixel(clip.minX + band), y: y, width: width, height: side)
            trailing.frame = CGRect(x: pixel(clip.maxX - width), y: y, width: width, height: side)
            if edges != chevrons {
                setShown(leading, edges.leading, was: chevrons.leading)
                setShown(trailing, edges.trailing, was: chevrons.trailing)
                chevrons = edges
            }
        }
        let showsPill = self.showsPill
        if showsPill {
            let pill = makePill()
            pill.frame = CGRect(x: pixel(runEnd + strip.newTabLeadingGap), y: y, width: pillWidth, height: side)
        }
        if let pill, pill.isHidden == showsPill { pill.isHidden = !showsPill }
    }

    /// The control under `point` (the strip's content view coordinates), for the strip's hit test: a shown chevron or
    /// the pill.
    func control(at point: CGPoint) -> NSView? {
        visibleControls.first { $0.frame.contains(point) }
    }

    /// The shown controls, for hit testing and VoiceOver.
    var visibleControls: [NSView] {
        var shown: [NSView] = []
        if chevrons.leading, let leadingChevron { shown.append(leadingChevron) }
        if chevrons.trailing, let trailingChevron { shown.append(trailingChevron) }
        if let pill, !pill.isHidden { shown.append(pill) }
        return shown
    }

    private func makeChevron(leading: Bool) -> TitlebarBandButton {
        let button = TitlebarBandButton(symbol: leading ? "chevron.left" : "chevron.right")
        button.symbolPointSize = { Metrics.addMenuChevronPointSize }
        button.target = self
        button.action = leading ? #selector(pageLeading) : #selector(pageTrailing)
        let label = leading ? Strings.overflowScrollLeading : Strings.overflowScrollTrailing
        button.setAccessibilityLabel(label)
        button.themedToolTip = label
        button.alphaValue = 0
        strip?.contentView.addSubview(button)
        if leading { leadingChevron = button } else { trailingChevron = button }
        return button
    }

    /// The pill for the current arm, made (or relabeled) on first use.
    @discardableResult
    private func makePill() -> TitlebarBandButton {
        let button: TitlebarBandButton
        if let pill {
            button = pill
        } else {
            button = TitlebarBandButton(symbol: "chevron.down")
            button.symbolPointSize = { Metrics.addMenuChevronPointSize }
            button.isHidden = true
            button.pressMenu = { [weak self] in self?.makeMenu() }
            strip?.contentView.addSubview(button)
            pill = button
        }
        let mode = experiment
        guard pillMode != mode else { return button }
        pillMode = mode
        pillWidthCache = nil
        let label = mode == .allTabs ? Strings.overflowAllTabs : Strings.overflowMore
        button.text = label
        // The chevron after the words: the pill reads "More ⌄", as a pop-up button does.
        button.imagePosition = .imageTrailing
        button.setAccessibilityLabel(label)
        button.setAccessibilityRole(.popUpButton)
        button.setAccessibilityIdentifier(mode == .allTabs ? "cmux.tabs.allTabs" : "cmux.tabs.more")
        return button
    }

    /// A chevron shows or goes with its edge's fade (the Motion `hover` fade, at once in a live resize).
    private func setShown(_ button: TitlebarBandButton, _ shown: Bool, was: Bool) {
        guard shown != was, let layer = button.layer else {
            button.alphaValue = shown ? 1 : 0
            return
        }
        let from = layer.presentation()?.opacity ?? layer.opacity
        let target: Float = shown ? 1 : 0
        button.alphaValue = CGFloat(target)
        if button.window == nil || Motion.isLiveResizing(button.window) {
            layer.removeAnimation(forKey: "opacity")
            return
        }
        Motion.tabs.set(layer, "opacity", to: target, fade: .hover, from: from)
    }

    @objc private func pageLeading() { strip?.scrollPage(by: -1) }
    @objc private func pageTrailing() { strip?.scrollPage(by: 1) }

    /// The pill's menu, built as it opens: More lists the hidden tabs, All Tabs every tab with the selected one
    /// checked.
    private func makeMenu() -> NSMenu? {
        guard let strip else { return nil }
        let model = strip.model
        let tabs: [TabItem]
        switch experiment {
        case .moreMenu: tabs = strip.overflowPartition.hidden.compactMap { model.tab($0) }
        case .allTabs: tabs = strip.displayed
        case .off, .chevrons: return nil
        }
        let menu = NSMenu(title: experiment == .allTabs ? Strings.overflowAllTabs : Strings.overflowMore)
        menu.autoenablesItems = false
        let iconSide = strip.metrics.iconSize
        for tab in tabs {
            let row = NSMenuItem(title: tab.title.isEmpty ? Strings.untitled : tab.title, action: #selector(pick(_:)), keyEquivalent: "")
            row.target = self
            row.representedObject = tab.id
            row.image = Self.menuImage(tab.icon, side: iconSide)
            if experiment == .allTabs, tab.id == model.selectedID { row.state = .on }
            menu.addItem(row)
        }
        strip.hoverCards.dismiss(.action)
        strip.menuTracking.begin(menu)
        return menu
    }

    /// A tab's icon for its menu row, where one is cheap to make (a symbol, a pack icon, a favicon).
    private static func menuImage(_ icon: TabIcon, side: CGFloat) -> NSImage? {
        switch icon {
        case .symbol(let name): NSImage.icon(symbol: name, size: side)
        case .icon(let name): NSImage.icon(name, size: side)
        case .image(let image): NSImage(cgImage: image.cgImage, size: NSSize(width: side, height: side))
        case .none, .agentMark: nil
        }
    }

    /// A menu row picked: its tab is selected (the strip lays the More row out again around it) and shown.
    @objc private func pick(_ sender: NSMenuItem) {
        guard let strip, let id = sender.representedObject as? TabID, strip.model.tab(id) != nil else { return }
        if strip.model.selectedID != id { strip.model.send(.select(id)) }
        strip.reveal(id, animated: !strip.reduceMotion)
    }
}
