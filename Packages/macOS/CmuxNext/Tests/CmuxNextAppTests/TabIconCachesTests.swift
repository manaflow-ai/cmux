import AppKit
import CmuxNextDesign
import CmuxNextIcons
@testable import CmuxNextTabs
import Testing

/// The tab strip's icon images come from one injected ``TabIconCaches`` (no process-wide image
/// caches): a strip hands its instance to every cell, group chip and its hover card body and draws
/// only into it, strips given one instance draw each icon once, and a cell's icon for each kind is
/// the injected cache's entry.
/// `TabIconCachesSharingTests` checks that the app's strips all get the composition root's one
/// instance.
@MainActor @Suite(.serialized) struct TabIconCachesTests {
    private static let tint = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1)

    private static func model() -> TabStripModel {
        TabStripModel(tabs: [
            TabItem(id: TabID("term"), title: "zsh", icon: .icon(.terminal)),
            TabItem(id: TabID("agent"), title: "Claude", icon: .agentMark("claude")),
            TabItem(id: TabID("sym"), title: "Star", icon: .symbol("star.fill")),
        ], selectedID: TabID("term"))
    }

    /// The strip with its tabs' cells made.
    private static func syncedStrip(_ caches: TabIconCaches) -> TabStripView {
        let strip = TabStripView(model: model(), iconCaches: caches)
        strip.sync(fromModel: true, animating: false)
        return strip
    }

    /// Two images with the same size and the same bytes.
    private static func samePixels(_ a: CGImage?, _ b: CGImage?) -> Bool {
        guard let a, let b, a.width == b.width, a.height == b.height,
              let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return false }
        return (da as Data) == (db as Data)
    }

    @Test func aStripDrawsOnlyIntoTheCachesItIsGiven() throws {
        let first = TabIconCaches()
        let second = TabIconCaches()
        let strip = Self.syncedStrip(first)
        let cell = try #require(strip.cells[TabID("term")])
        #expect(cell.iconCaches === first, "the strip did not hand its caches to its cell")
        let drawn = first.entryCount
        #expect(drawn > 0, "the strip drew its icons from somewhere other than its injected caches")
        #expect(second.entryCount == 0, "a strip's icon draws reached caches it was not given")

        let other = Self.syncedStrip(second)
        #expect(other.cells[TabID("term")]?.iconCaches === second)
        #expect(second.entryCount > 0)
        #expect(first.entryCount == drawn, "the second strip's draws landed in the first strip's caches")
    }

    @Test func stripsGivenOneInstanceDrawEachIconOnce() {
        let shared = TabIconCaches()
        _ = Self.syncedStrip(shared)
        let drawn = shared.entryCount
        #expect(drawn > 0)
        _ = Self.syncedStrip(shared)
        #expect(shared.entryCount == drawn, "a second strip on the same caches drew its icons again")
    }

    @Test func aCellDrawsEachKindOfIconFromTheInjectedCaches() throws {
        let caches = TabIconCaches()
        func cell(_ icon: TabIcon) -> TabCell {
            TabCell(item: TabItem(id: TabID("t"), title: "t", icon: icon), iconCaches: caches)
        }
        let tint = Self.tint.cgColor

        // Pack icon: the pack's own drawing at the cell's icon size.
        let pack = cell(.icon(.terminal))
        let packImage = try #require(pack.iconImage(tint: Self.tint))
        let packReference = CGImage.icon(.terminal, size: pack.metrics.iconSize, scale: pack.scale, tint: tint)
        #expect(Self.samePixels(packImage, packReference))
        #expect(packImage === caches.packIcons.image(name: .terminal, tint: Self.tint, size: pack.metrics.iconSize, scale: pack.scale),
                "the cell's pack icon is not the injected cache's entry")

        // Agent mark: the same pixels a separate cache draws (this checks the cell's inputs, not the drawing code).
        let agent = cell(.agentMark("claude"))
        let agentImage = try #require(agent.iconImage(tint: Self.tint))
        let agentReference = TabAgentMarkCache().image(brand: "claude", tint: Self.tint, size: agent.metrics.iconSize, scale: agent.scale)
        #expect(Self.samePixels(agentImage, agentReference))
        #expect(agentImage === caches.agentMarks.image(brand: "claude", tint: Self.tint, size: agent.metrics.iconSize, scale: agent.scale))

        // SF Symbol: at the small icon point size inside the icon box, as a separate cache draws it.
        let symbol = cell(.symbol("star.fill"))
        let symbolImage = try #require(symbol.iconImage(tint: Self.tint))
        let symbolReference = TabSymbolCache().image(named: "star.fill", tint: Self.tint, pointSize: Metrics.smallIconSize,
                                                     size: symbol.metrics.iconSize, scale: symbol.scale)
        #expect(Self.samePixels(symbolImage, symbolReference))
        #expect(symbolImage === caches.symbols.image(named: "star.fill", tint: Self.tint, pointSize: Metrics.smallIconSize,
                                                    size: symbol.metrics.iconSize, scale: symbol.scale))

        // A user image (an emoji drawn to an image, a stored asset): drawn as is, no cache entry.
        let before = caches.entryCount
        let emoji = try #require(TabUserIcon.shared.icon("🚀"))
        guard case .image(let picture) = emoji else {
            Issue.record("an emoji user icon is not an image")
            return
        }
        let user = cell(emoji)
        #expect(user.iconImage(tint: Self.tint) === picture.cgImage)
        #expect(caches.entryCount == before, "a user image went through the tinted caches")
    }

    /// The hover card body draws the hovered tab's glyph into the strip's caches. A card body with
    /// its own caches would draw each tab glyph again for each strip.
    @Test func theHoverCardBodyDrawsTheTabGlyphIntoTheStripsCaches() throws {
        let caches = TabIconCaches()
        let tab = TabItem(id: TabID("agent"), title: "Claude", icon: .agentMark("claude"))
        // Not synced: the strip has no cells yet, so every entry below is the card's.
        let strip = TabStripView(model: TabStripModel(tabs: [tab], selectedID: tab.id), iconCaches: caches)
        try #require(caches.entryCount == 0, "the strip drew icons before its first sync")

        let body = try #require(strip.hoverCard.hoverCardBody(for: TabHoverCardController.targetID(tab.id)),
                                "the strip's hover card has no body for its tab")
        body.applyTheme()
        #expect(caches.entryCount > 0, "the hover card body drew the tab's glyph into caches the strip did not give it")
    }

    /// A group chip draws its icon from the strip's caches.
    @Test func aGroupChipDrawsFromTheStripsCaches() throws {
        let caches = TabIconCaches()
        let group = TabGroupItem(id: "G", name: "API", icon: .symbol("star.fill"))
        let model = TabStripModel(tabs: [TabItem(id: "a", title: "a", groupID: "G"), TabItem(id: "b", title: "b", groupID: "G")],
                                  groups: [group], selectedID: "a")
        let strip = TabStripView(model: model, iconCaches: caches)
        strip.sync(fromModel: true, animating: false)
        let chip = try #require(strip.groups.chips["G"], "the strip made no chip for its group")
        #expect(chip.iconCaches === caches, "the strip did not hand its caches to its group chip")
    }
}
