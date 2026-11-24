public import CoreGraphics
public import CmuxNextDesign
import CmuxNextSettings
import Foundation

/// A chat's header tools in its pane's tab row (header/tabRow.ts):
/// the width the page last reported for them (`pane.tabRowTools {width}`, CSS pixels) and the row
/// last offered to the page (the `tabRow` event, CSS pixels; height 0 ends the page's one-row
/// mode). Kept on the model: ``AgentPaneView`` is at its size limit.
@MainActor public final class AgentPaneTabRow {
    /// The page's tools' width in CSS pixels, gap included; 0 while it draws no tools in the row.
    public private(set) var toolsWidth: CGFloat = 0
    /// The last positive ``toolsWidth``, kept after the row ends or the page loads again: whether
    /// the tools fit a pane's row (`PaneTabRowSharing.fitsTabRow`); 0 before the page first reported.
    public private(set) var neededWidth: CGFloat = 0
    /// Called when ``toolsWidth`` changes, or the page loads again (the pane lays out again).
    public var onChange: (() -> Void)?
    /// The row last pushed to the page, nil before the first.
    private(set) var offered: (height: CGFloat, trailingInset: CGFloat, soloTab: Bool, accessoryRoom: CGFloat?)?
    /// The most the row's accessories (the rolling summary) may take, in points (`PaneTabRowSharing.setTabRowAccessoryRoom`):
    /// the room the pane's tabs leave at their full width (#53314); `.infinity` sets no limit.
    var accessoryRoom: CGFloat = .infinity
    /// The pane draws its tabs at the row's leading end; false while a lone tab hides (`PaneTabRowSharing.setTabRowTabs`).
    var tabsShown = true
    /// Native chrome holes, in the chat view's coordinates; Session Info adds its own overlay hole. Turned into the
    /// page's coordinates at each apply (``AgentPaneView/applyNativeRects()``), so a page the view lays elsewhere for a
    /// while (held away while an adopted chat draws) gets them back where it shows.
    var holes: [CGRect] = []
    /// What the pane's toolbar hole paints (``holeFill(chromium:shares:tabsShown:page:)``), set with each offer.
    public private(set) var holeFill: CGColor?
    /// The window's top rim the page leaves uncovered over the chat's tools (`nativeHoles`), in points; the
    /// toolbar's fill leaves it too (``PaneTabRowRim``).
    static let rimHeight: CGFloat = PaneTabRowRim.height
    private var offeredNativeRowTools: Bool?
    /// Only a shared page host has the return event stream needed by native controls.
    var supportsNativeTools = false
    public var nativeToolsEnabled: Bool { supportsNativeTools && ChromeTunables.nativeRowTools.value }

    /// The page loaded again and has not reported since: its tools keep their place in the row until it does
    /// (``sharedWidth(zoom:)``). A report, 0 included, ends it.
    private var awaitingReport = false

    /// Where the tools' last width is kept across launches (``AgentPaneModel`` passes the app's defaults; nil keeps
    /// nothing, as in tests).
    private let defaults: UserDefaults?
    static let keptWidthKey = "agentPane.tabRowToolsWidth"

    /// A new chat view's row. With a width kept from an earlier launch, the row starts as a reloaded page's does
    /// (``sharedWidth(zoom:)``): the pane lays the chat under the strip from its first layout. A row that waited for
    /// the page's first report laid the chat below the strip, then under it once the page reported, after every
    /// launch: the header grew by 6 and the composer dropped by the row's 34 just after the chat drew (relaunch-shift
    /// bench; Leo, 2026-11-14: "too much render shift when the thing restarts to update").
    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        let kept = CGFloat(defaults?.double(forKey: Self.keptWidthKey) ?? 0)
        if kept > 0 {
            neededWidth = kept
            awaitingReport = true
        }
    }

    /// The page reported its tools' width, and their `need`: the width less what takes only the row's leftover room
    /// (the chat's rolling summary, header/tabRow.ts TAB_ROW_ACCESSORY). The need, not the width, is what decides
    /// whether a pane offers the row: a summary measured in a wide pane made the tools need more than half of the row
    /// once the pane was split, and the chat's tools dropped to a second row under the tabs (Leo 2026-11-22: "the icons
    /// on the top right have gotten displaced due to putting things on a line"). A page that sends no need (older) has
    /// its width as the need.
    func report(width: CGFloat, need: CGFloat? = nil) {
        if width > 0 {
            let needed = min(width, need.map { $0 > 0 ? $0 : width } ?? width)
            if abs(needed - neededWidth) >= 0.5 { defaults?.set(Double(needed), forKey: Self.keptWidthKey) }
            neededWidth = needed
        }
        let awaited = awaitingReport
        awaitingReport = false
        guard width != toolsWidth || awaited else { return }
        toolsWidth = width
        onChange?()
    }

    /// The page loaded again (its handshake): it draws no tools in the row and was offered none,
    /// so the pane's next layout offers the row again.
    func pageLoaded() {
        guard offered != nil || toolsWidth != 0 else { return }
        offered = nil
        offeredNativeRowTools = nil
        toolsWidth = 0
        awaitingReport = neededWidth > 0
        onChange?()
    }

    /// The `tabRow` event for the row last offered (a page that subscribes again gets it first).
    var event: AgentPageEvent {
        .tabRow(height: offered?.height ?? 0, trailingInset: offered?.trailingInset ?? 0,
                nativeRowTools: offeredNativeRowTools ?? false, soloTab: offered?.soloTab ?? false, accessoryRoom: offered?.accessoryRoom)
    }

    /// The tools' width in points at `zoom` (points per CSS pixel); nil while the page draws no tools in the row. A page
    /// that loaded again (a discarded chat shown, a reload) keeps its ``sharedNeed(zoom:)`` until it reports: a pane that
    /// followed the 0 laid the chat under the strip until the width came back, so its tools showed in a second row under
    /// the tabs and then jumped up into the row under the pointer (Leo 2026-11-07: "the top right button area is
    /// somehow, like, shifting its layout"). A 0 the page reports is its tools leaving the row (a replay, a quick
    /// surface), and the tabs take the row back; a row offered anew gets the width again with no 0 (header/tabRow.ts).
    public func sharedWidth(zoom: CGFloat) -> CGFloat? {
        if toolsWidth > 0 { return toolsWidth * max(0.25, zoom) }
        return awaitingReport ? sharedNeed(zoom: zoom) : nil
    }

    /// ``neededWidth`` in points at `zoom`; nil before the page reported (its first offer learns it).
    public func sharedNeed(zoom: CGFloat) -> CGFloat? {
        guard neededWidth > 0 else { return nil }
        return neededWidth * max(0.25, zoom)
    }

    /// Offers `view`'s page the top `height` points of the pane, less `trailingInset` at the trailing
    /// end (0: no row), converted to CSS pixels; pushed only when it changed.
    public static func offer(points height: CGFloat, trailingInset: CGFloat, to view: AgentPaneView) {
        let zoom = max(0.25, view.webView.pageZoom)
        let on = height > 0
        let nativeRowTools = view.model.tabRow.nativeToolsEnabled
        let row = view.model.tabRow
        let next = (height: on ? height / zoom : 0, trailingInset: on ? max(0, trailingInset) / zoom : 0, soloTab: on && !row.tabsShown,
                    accessoryRoom: on ? accessoryRoomCSS(row.accessoryRoom / zoom) : nil)
        let shares = on && row.sharedWidth(zoom: zoom) != nil
        view.setTabRowCover(shares ? height : 0) // the pane lays the view under the strip only then
        // The engine, not the shared host (which runs WebKit too, where the page is under the toolbar).
        row.holeFill = holeFill(chromium: view.chromiumPage != nil, shares: shares, tabsShown: row.tabsShown,
                                page: view.performWithTheme { AgentPaneTheme.pageBackground(view.themeTokens, surface: view.surfaceKind) })
        if view.page != nil {
            // A Chromium chat is a window above the pane: it leaves the pane's tabs and toolbar uncovered.
            // The holes are worked out from the row's top-left corner; the chat view is not flipped, so
            // each one is mirrored from its own maxY (a hole shorter than the row, the rim's, stays at the
            // top; at y 0 they cut the composer's footer out of the page instead).
            let bounds = view.bounds, flipped = view.isFlipped
            let holes = shares ? nativeHoles(width: bounds.width, height: height, trailingInset: max(0, trailingInset),
                                             tools: min(row.sharedWidth(zoom: zoom) ?? 0, (row.sharedNeed(zoom: zoom) ?? .infinity) + row.accessoryRoom), tabs: row.tabsShown) : []
            row.holes = holes.map { hole in
                let y = flipped ? bounds.minY + hole.minY : bounds.maxY - hole.maxY
                return CGRect(x: bounds.minX + hole.minX, y: y, width: hole.width, height: hole.height)
            }
            view.applyNativeRects()
        }
        guard row.offered.map({ $0 != next || row.offeredNativeRowTools != nativeRowTools }) ?? (next.height > 0 || nativeRowTools) else { return }
        row.offered = next
        row.offeredNativeRowTools = nativeRowTools
        let event = row.event
        view.deliver([event], scripts: ["window.cmuxAcpmuxBridge?.applyTabRow?.(\(event.value.compactText));"])
    }

    /// The widest the page's rolling summary is (header.css `.acpmux-chat-summary--inline`, 300px) plus its gap, and the
    /// narrowest it shows at (header/tabRow.ts TAB_ROW_ACCESSORY_MIN): the room is offered in whole CSS pixels within
    /// them, so a pane spring or a divider drag offers the row again only while the room is between the two.
    static let accessoryRoomMax: CGFloat = 320
    static let accessoryRoomMin: CGFloat = 168 // 160 and the widest gap the page takes off before its own minimum

    /// `css` (the accessories' room in CSS pixels) as offered to the page: nil for no limit, 0 under the narrowest summary.
    static func accessoryRoomCSS(_ css: CGFloat) -> CGFloat? {
        guard css.isFinite else { return nil }
        let room = min(accessoryRoomMax, max(0, css)).rounded(.down)
        return room < accessoryRoomMin ? 0 : room
    }

    /// The color the pane's toolbar hole paints so the row reads as one surface (``PaneTabRowSharing/tabRowHoleFill``):
    /// a Chromium chat is a window above the pane that leaves the toolbar uncovered, and alone in its pane its page
    /// paints `page` (`--cmux-surface-background`) across the whole row (header.css, `[data-solo-tab]`), so the hole
    /// paints it too. With its tabs shown the page leaves the row clear, and on WebKit the page is under the toolbar:
    /// nil, as is a clear page color. A theme change lays the pane out again, which offers the row and reads it anew.
    static func holeFill(chromium: Bool, shares: Bool, tabsShown: Bool, page: @autoclosure () -> ThemeRGB) -> CGColor? {
        guard chromium, shares, !tabsShown else { return nil }
        let color = page()
        return color.alpha > 0 ? color.cgColor : nil
    }
}

/// The parts of a shared tab row `width` points wide and `height` tall (top-left origin) that the
/// pane's native chrome draws: its tabs, from the leading edge to where the chat's `tools` begin
/// (the strip gives up at most half its room, `PaneTabRowSharing.tabRowWidth`), unless `tabs` is
/// false (a lone tab hides), and its toolbar in the trailing `trailingInset` points. Between them,
/// the row's top `AgentPaneTabRow.rimHeight` stays uncovered too: where the row meets the window's
/// top edge, the page window over it drew a flat gray line in place of the window's lit glass rim,
/// so the rim broke off where the chat's tools began (Leo 2026-11-03: "there is clearly a rectangle
/// that is just covering up the glass at the rim of the top of the app"). The three never overlap:
/// the fork masks the page with them even-odd, and an overlap would cover that part again.
private func nativeHoles(width: CGFloat, height: CGFloat, trailingInset: CGFloat, tools: CGFloat, tabs: Bool) -> [CGRect] {
    let room = max(0, width - trailingInset)
    let span = min(max(0, tools), room / 2)
    let tabsEnd = tabs ? room - span : 0
    return [CGRect(x: 0, y: 0, width: tabsEnd, height: height),
            CGRect(x: tabsEnd, y: 0, width: room - tabsEnd, height: min(AgentPaneTabRow.rimHeight, height)),
            CGRect(x: room, y: 0, width: width - room, height: height)].filter { !$0.isEmpty }
}

extension AgentPageEvent {
    /// The tab row the chat header's tools may sit in (`tabRow`): `{height, trailingInset, nativeRowTools, soloTab}`;
    /// `soloTab`: the pane holds this one tab, and the page runs its transcript up under the row (header/tabRow.ts).
    /// `accessoryRoom`: the most the row's accessories (the rolling summary) may take, CSS pixels; nil sends none (no limit).
    static func tabRow(height: CGFloat, trailingInset: CGFloat, nativeRowTools: Bool, soloTab: Bool = false, accessoryRoom: CGFloat? = nil) -> AgentPageEvent {
        var value: [String: JSONValue] = ["height": .number(Double(height)), "trailingInset": .number(Double(trailingInset)),
                                          "nativeRowTools": .bool(nativeRowTools), "soloTab": .bool(soloTab)]
        if let accessoryRoom { value["accessoryRoom"] = .number(Double(accessoryRoom)) }
        return AgentPageEvent(kind: "tabRow", value: .object(value))
    }
}

/// A chat's header tools share its pane's tab row (the conformance is the App's, PaneContentView+Parking).
extension PaneTabRowSharing where Self: AgentPaneView {
    public var tabRowToolsWidth: CGFloat? { model.tabRow.sharedWidth(zoom: webView.pageZoom) }
    public var tabRowToolsNeed: CGFloat? { model.tabRow.sharedNeed(zoom: webView.pageZoom) }
    public var onTabRowToolsChange: (() -> Void)? { get { model.tabRow.onChange } set { model.tabRow.onChange = newValue } }
    public func setTabRow(height: CGFloat, trailingInset: CGFloat) { AgentPaneTabRow.offer(points: height, trailingInset: trailingInset, to: self) }
    public func setTabRowTabs(shown: Bool) { model.tabRow.tabsShown = shown }
    public func setTabRowAccessoryRoom(_ points: CGFloat) { model.tabRow.accessoryRoom = points }
    public var tabRowTakesLoneTab: Bool { true }
    public var tabRowHoleFill: CGColor? { model.tabRow.holeFill }
}
