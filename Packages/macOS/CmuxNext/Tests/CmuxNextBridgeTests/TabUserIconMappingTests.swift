import CmuxNextIcons
@testable import CmuxNextDaemon
import CmuxNextTabs
import Testing
@testable import CmuxNextBridge

/// ICON-PICKER-ALL-EMOJI-AND-SF-SYMBOLS: the icon a user set on a tab replaces
/// its kind icon in the strip (pinned tabs draw the same item, icon only). An
/// emoji draws in full color, an SF Symbol tinted; a wire string that is not an
/// icon, or a symbol this Mac cannot draw, keeps the kind icon; clearing restores it.
@MainActor
struct TabUserIconMappingTests {
    private func tab() throws -> TabModel {
        let store = try BridgeFixture.store()
        return try #require(store.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).first)
    }

    @Test func aSymbolIconReplacesTheKindIcon() throws {
        let tab = try tab()
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .icon(.terminal))
        tab.userIcon = "hammer.fill"
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .symbol("hammer.fill"))
        tab.setAgent(AgentStatus(surface: 1, state: .working, agent: "claude"))
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .symbol("hammer.fill"))
        tab.userIcon = nil
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .agentMark("claude"))
    }

    @Test func anEmojiIconDrawsAFullColorImage() throws {
        let tab = try tab()
        tab.userIcon = "🚀"
        guard case .image(let image) = TabItemMapping.shared.item(tab, fallbackTitle: "t").icon else {
            Issue.record("an emoji icon must draw as an image")
            return
        }
        #expect(image.cgImage.width >= 32 && image.cgImage.width == image.cgImage.height)
        // The same emoji is drawn once; the strip compares images by identity.
        #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .image(image))
    }

    @Test func anInvalidOrUndrawableIconKeepsTheKindIcon() throws {
        let tab = try tab()
        for wire in ["Not An Icon", "🚀🚀", "zz.no.such.symbol.cmux"] {
            tab.userIcon = wire
            #expect(TabItemMapping.shared.item(tab, fallbackTitle: "t").icon == .icon(.terminal), "\(wire)")
        }
    }
}
