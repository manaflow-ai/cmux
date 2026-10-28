import AppKit
import CmuxNextDesign
@testable import CmuxNextTabs
import QuartzCore
import Testing

/// Lawrence 2026-10-19: a tab showed two unread marks, one on its favicon's corner and one at its
/// end. "There should only ever be a single unread indicator for the right side", and "nothing
/// should ever be on the left side besides the favicon": the leading slot draws only the favicon
/// or the tab's icon, and every mark (unread or status, loading, audio) draws in the trailing
/// cluster, ordered left to right title, loading, audio, the unread/status mark, then the x.
@MainActor @Suite(.serialized) struct TabSingleTrailingIndicatorTests {
    private static let favicon: TabImage = {
        let context = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return TabImage(context.makeImage()!)
    }()

    enum Kind: String, CaseIterable, Sendable {
        case browserWithFavicon, browserWithoutFavicon, terminal, agentChat
    }

    private static func icon(_ kind: Kind) -> TabIcon {
        switch kind {
        case .browserWithFavicon: .image(favicon)
        case .browserWithoutFavicon: .icon(.browser)
        case .terminal: .icon(.terminal)
        case .agentChat: .agentMark("claude")
        }
    }

    private static func cell(_ kind: Kind, unread: Bool = true, status: TabStatus = .none, busy: Bool = false,
                             audio: Bool = false, selected: Bool = false, width: CGFloat = 220) -> TabCell {
        var item = TabItem(id: TabID(kind.rawValue), title: "A page title", icon: icon(kind), isUnread: unread, isBusy: busy, status: status)
        if busy { item.indicator = kind == .agentChat ? .working(progress: nil) : .busy(progress: nil) }
        if audio { item.audio = .playing }
        let cell = TabCell(item: item)
        cell.isSelected = selected
        cell.frame = CGRect(x: 0, y: 0, width: width, height: 32)
        cell.layoutLayers()
        return cell
    }

    /// The icon slot's frame in the cell.
    private static func iconFrame(_ cell: TabCell) -> CGRect {
        let icon = cell.iconLayer
        return CGRect(x: icon.position.x - icon.bounds.width / 2, y: icon.position.y - icon.bounds.height / 2,
                      width: icon.bounds.width, height: icon.bounds.height)
    }

    /// Every drawn mark: the unread or status dot, a status set's glyph, the loading indicator and the speaker.
    private static func marks(_ cell: TabCell) -> [(name: String, frame: CGRect)] {
        var marks: [(String, CGRect)] = []
        if let badge = cell.badgeLayer, badge.opacity > 0, !badge.isHidden { marks.append(("unread", badge.frame)) }
        if let glyph = cell.statusGlyphLayer, glyph.layer.opacity > 0, !glyph.layer.isHidden { marks.append(("status", glyph.frame)) }
        if let spinner = cell.spinnerLayer, spinner.layer.opacity > 0, !spinner.layer.isHidden { marks.append(("loading", spinner.frame)) }
        if let audio = cell.audioLayer, audio.opacity > 0 { marks.append(("audio", audio.frame)) }
        return marks
    }

    @Test(arguments: Kind.allCases) func anUnreadTabShowsExactlyOneUnreadDotOnTheTrailingEdge(kind: Kind) throws {
        for selected in [false, true] {
            let cell = Self.cell(kind, selected: selected)
            let unread = Self.marks(cell).filter { $0.name == "unread" || $0.name == "status" }
            #expect(unread.count == 1, "\(kind) selected \(selected): \(unread.count) unread marks")
            let dot = try #require(unread.first?.frame)
            let icon = Self.iconFrame(cell)
            #expect(!dot.intersects(icon), "\(kind): the unread dot sits on the icon (\(dot) on \(icon))")
            #expect(dot.minX > cell.bounds.midX, "\(kind): the unread dot is not on the trailing side (\(dot))")
            if let close = cell.closeButtonRect {
                #expect(dot.maxX <= close.minX, "\(kind): the unread dot is not left of the x (\(dot), \(close))")
            }
        }
    }

    @Test(arguments: Kind.allCases) func aStatusDotIsTheOneTrailingMarkToo(kind: Kind) throws {
        for status in [TabStatus.needsInput, .success, .failure] {
            let cell = Self.cell(kind, unread: true, status: status)
            let dots = Self.marks(cell).filter { $0.name == "unread" || $0.name == "status" }
            #expect(dots.count == 1, "\(kind) \(status): \(dots.count) marks")
            let dot = try #require(dots.first?.frame)
            #expect(!dot.intersects(Self.iconFrame(cell)), "\(kind) \(status): the mark sits on the icon")
        }
    }

    @Test(arguments: Kind.allCases) func aLoadingTabKeepsItsIconAndShowsTheIndicatorOnTheRight(kind: Kind) throws {
        let cell = Self.cell(kind, unread: true, busy: true, audio: true)
        let icon = Self.iconFrame(cell)
        #expect(cell.iconLayer.opacity == 1, "\(kind): the loading indicator hides the icon")
        let marks = Self.marks(cell)
        for mark in marks {
            #expect(!mark.frame.intersects(icon), "\(kind): \(mark.name) draws on the icon (\(mark.frame))")
            #expect(mark.frame.minX > cell.bounds.midX, "\(kind): \(mark.name) is not on the trailing side")
        }
        let byName = Dictionary(uniqueKeysWithValues: marks.map { ($0.name, $0.frame) })
        let loading = try #require(byName["loading"], "\(kind): no loading indicator")
        let audio = try #require(byName["audio"], "\(kind): no speaker")
        let unread = try #require(byName["unread"], "\(kind): no unread dot")
        // Left to right: title, loading, audio, the unread dot at the far right.
        #expect(loading.maxX <= audio.minX, "\(kind): loading \(loading) is not left of the speaker \(audio)")
        #expect(audio.maxX <= unread.minX, "\(kind): the speaker \(audio) is not left of the unread dot \(unread)")
    }

    @Test func nothingButTheFaviconDrawsInTheLeadingSlot() {
        let cell = Self.cell(.browserWithFavicon, unread: true, status: .success, busy: true, audio: true, selected: true)
        let icon = Self.iconFrame(cell)
        let titleStart = cell.titleLayer.frame.minX
        let allowed: [CALayer?] = [cell.backgroundLayer, cell.iconLayer, cell.titleLayer, cell.separatorLayer, cell.hibernationRingLayer]
        for part in cell.layer.sublayers ?? [] where !allowed.contains(where: { $0 === part }) {
            guard part.opacity > 0, !part.isHidden, part.frame.width > 0 else { continue }
            #expect(part.frame.minX >= titleStart, "a part draws left of the title: \(part) at \(part.frame), icon \(icon)")
        }
    }

    /// Chrome's favicon to title gap (6 pt at the standard density).
    @Test func theIconToTitleGapIsChromeLike() {
        let cell = Self.cell(.browserWithFavicon)
        let gap = cell.titleLayer.frame.minX - Self.iconFrame(cell).maxX
        #expect(gap == (Metrics.compactTabs ? Metrics.space2 : Metrics.space3), "gap \(gap)")
    }
}
