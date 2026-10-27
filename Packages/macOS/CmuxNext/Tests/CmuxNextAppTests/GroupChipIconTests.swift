import AppKit
import CmuxNextActions
@testable import CmuxNextApp
import CmuxNextBridge
import CmuxNextBridgeUI
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import Foundation
import Testing

/// Screen groups and tab groups carry an icon (`screen-group-icon-v1`, `tab-group-icon-v1`), the
/// shared icon string: an emoji, an SF Symbol name or a stored asset (cx-qno.11.2). The daemon's
/// group decodes it, the chip draws it before the name, and Set/Remove Group Icon takes an icon
/// argument from the CLI and MCP under the same rule as workspace groups.
@MainActor
struct GroupChipIconTests {
    static let asset = "svg:sha256-" + String(repeating: "d", count: 64)
    static let svg = Data(##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16"><path d="M0 0h16v16H0z" fill="#d22"></path></svg>"##.utf8)

    static func image() throws -> TabImage {
        TabImage(try #require(IconAssetImages.decode(svg, mediaType: "image/svg+xml")))
    }

    // MARK: Screen group chips

    func screenChips(_ icons: [String?], asset: @escaping (String) -> TabImage? = { _ in nil }) throws -> [TabGroupItem] {
        let store = DaemonStore()
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w")]))
        let workspace = try #require(store.workspaces.first)
        workspace.screenGroups = icons.enumerated().map { index, icon in
            ScreenGroupSnapshot(id: ScreenGroupID(rawValue: "g\(index)"), name: "Group \(index)", color: "blue", icon: icon)
        }
        return ScreenBarMapping.shared.snapshot(workspace, untitled: { "Screen \($0)" }, emojiIcon: { .symbol("emoji:\($0)") },
                                                assetIcon: asset).groups
    }

    @Test func aScreenGroupChipShowsItsEmojiSymbolOrStoredIcon() throws {
        let image = try Self.image()
        let chips = try screenChips(["🚀", "star.fill", Self.asset, nil], asset: { $0 == Self.asset ? image : nil })
        #expect(chips.map(\.icon) == [.symbol("emoji:🚀"), .symbol("star.fill"), .image(image), nil])
    }

    /// Until the stored asset is read the chip keeps the placeholder symbol, so the chip does not
    /// change width when the image arrives.
    @Test func aScreenGroupChipShowsThePlaceholderWhileItsAssetLoads() throws {
        #expect(try screenChips([Self.asset]).first?.icon == .symbol("photo"))
    }

    // MARK: Tab group chips

    func tabChip(_ icon: String?, asset: (String) -> TabImage? = { _ in nil }) throws -> TabGroupItem {
        let store = DaemonStore()
        let group = TabGroupSnapshot(id: "tg", name: "API", color: "red", surfaces: [1], icon: icon)
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1)], tabGroups: [group])
        let screen = ScreenSnapshot(id: 1, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, name: "w", screens: [screen])]))
        let model = try #require(store.workspaces.first?.screens.first?.panes.first?.tabGroups.first)
        return TabItemMapping.shared.groupItem(model, isSaved: false, asset: asset)
    }

    @Test func aTabGroupChipShowsItsIconThroughThePaneStripMapping() throws {
        let image = try Self.image()
        #expect(try tabChip("star.fill").icon == .symbol("star.fill"))
        #expect(try tabChip(Self.asset, asset: { $0 == Self.asset ? image : nil }).icon == .image(image))
        #expect(try tabChip(Self.asset).icon == .symbol("photo"), "the placeholder while the asset loads")
        guard case .image? = try tabChip("🚀").icon else {
            Issue.record("an emoji draws as a full-color image, like a tab's emoji icon")
            return
        }
        let plain = try tabChip(nil)
        #expect(plain.icon == nil)
        #expect(plain == TabGroupItem(id: "tg", name: "API", colorToken: .red), "no icon: the chip is unchanged")
    }

    // MARK: Chip layout

    @Test func aChipWithAnIconIsWiderAndOneWithoutIsUnchanged() {
        let plain = TabGroupChipCell(group: TabGroupItem(id: "g", name: "Frontend"), memberCount: 2)
        let none = TabGroupChipCell(group: TabGroupItem(id: "g", name: "Frontend", icon: nil), memberCount: 2)
        let iconed = TabGroupChipCell(group: TabGroupItem(id: "g", name: "Frontend", icon: .symbol("star.fill")), memberCount: 2)
        #expect(none.slotWidth == plain.slotWidth)
        #expect(iconed.slotWidth > plain.slotWidth)

        let metrics = TabStripMetrics.standard
        let named = TabGroupChipLayout.Content(nameWidth: 40, countWidth: nil)
        #expect(TabGroupChipLayout.pillWidth(named, metrics: metrics)
            == TabGroupChipLayout.pillWidth(TabGroupChipLayout.Content(nameWidth: 40, countWidth: nil, iconWidth: 0), metrics: metrics))
        // An unnamed group with an icon shows the icon in a pill, not the bare color dot.
        let iconOnly = TabGroupChipLayout.Content(nameWidth: 0, countWidth: nil, iconWidth: metrics.iconSize)
        #expect(TabGroupChipLayout.pillWidth(iconOnly, metrics: metrics) > metrics.groupChipDotSize)
    }

    // MARK: Decoding

    @Test func groupSnapshotsDecodeTheirIconAndDefaultToNone() throws {
        let decoder = JSONDecoder()
        func data(_ json: String) -> Data { Data(json.utf8) }
        let tab = try decoder.decode(TabGroupSnapshot.self, from: data(##"{"id":"tg","name":"API","icon":"star.fill"}"##))
        #expect(tab.icon == "star.fill")
        #expect(try decoder.decode(TabGroupSnapshot.self, from: data(##"{"id":"tg"}"##)).icon == nil)
        #expect(try decoder.decode(TabGroupSnapshot.self, from: data(##"{"id":"tg","icon":null}"##)).icon == nil)

        let screen = try decoder.decode(ScreenGroupSnapshot.self, from: data(##"{"id":"sg","icon":"\##(Self.asset)"}"##))
        #expect(screen.icon == Self.asset)
        #expect(try decoder.decode(ScreenGroupSnapshot.self, from: data(##"{"id":"sg"}"##)).icon == nil)

        let savedTab = try decoder.decode(SavedTabGroupSnapshot.self, from: data(##"{"id":"st","icon":"🚀","members":[]}"##))
        #expect(savedTab.icon == "🚀")
        #expect(try decoder.decode(SavedTabGroupSnapshot.self, from: data(##"{"id":"st"}"##)).icon == nil)

        let savedScreen = try decoder.decode(SavedScreenGroupSnapshot.self, from: data(##"{"id":"ss","icon":"folder"}"##))
        #expect(savedScreen.icon == "folder")
        #expect(try decoder.decode(SavedScreenGroupSnapshot.self, from: data(##"{"id":"ss"}"##)).icon == nil)

        let state = try decoder.decode(StateScreenGroup.self, from: data(##"{"id":"sgrp_1","workspace_id":"ws","name":"","collapsed":false,"screen_ids":[],"icon":"star"}"##))
        #expect(state.icon == "star")
        #expect(try decoder.decode(StateScreenGroup.self, from: data(##"{"id":"sgrp_1","workspace_id":"ws","name":"","collapsed":false,"screen_ids":[]}"##)).icon == nil)
    }

    /// The v2 state path carries the icon into the app's screen group.
    @Test func aStateScreenGroupKeepsItsIcon() throws {
        let store = DaemonStore()
        let screenResource = ResourceID(rawValue: "screen_1"), workspaceResource = ResourceID(rawValue: "ws_1")
        let pane = PaneSnapshot(id: 1, tabs: [TabSnapshot(surface: 1)])
        let screen = ScreenSnapshot(id: 1, resourceID: screenResource, layout: .leaf(1), panes: [pane])
        store.apply(snapshot: DaemonTree(workspaces: [WorkspaceSnapshot(id: 1, key: nil, resourceID: workspaceResource, name: "w", screens: [screen])]))
        let workspace = try #require(store.workspaces.first)
        var mirror = SessionStateMirror()
        mirror.screenGroups["sgrp_1"] = StateScreenGroup(id: "sgrp_1", workspaceID: workspaceResource, name: "Ops",
                                                         screenIDs: [screenResource], icon: "star")
        let groups = SessionStateStore.screenGroups(mirror, workspace: workspaceResource, screens: workspace.screens)
        #expect(groups.first?.icon == "star")
    }

    // MARK: Set Icon actions

    @Test func setGroupIconRefusesAnInvalidIconAndTakesAStoredAsset() throws {
        func invocation(_ icon: String?) -> ActionInvocation {
            ActionInvocation(arguments: icon.map { ["icon": .string($0)] } ?? [:], origin: .cli)
        }
        #expect(throws: ActionFailure.self) { try GroupIconArgument.icon(in: invocation("Not An Icon")) }
        #expect(throws: ActionFailure.self) { try GroupIconArgument.icon(in: invocation("svg:not-a-digest")) }
        #expect(try GroupIconArgument.icon(in: invocation(Self.asset)) == Self.asset)
        #expect(try GroupIconArgument.icon(in: invocation(" star.fill ")) == "star.fill")
        #expect(try GroupIconArgument.icon(in: invocation(nil)) == nil, "no argument: the picker opens")
        #expect(try GroupIconArgument.icon(in: invocation("")) == nil)

        for (id, target) in [("screenGroup.setIcon", ActionTargetKind.screenGroup), ("screenGroup.clearIcon", .screenGroup),
                             ("tabGroup.setIcon", .tabGroup), ("tabGroup.clearIcon", .tabGroup)] {
            let descriptor = try #require(ActionCatalog.all.first { $0.id.rawValue == id }, "\(id) is in the catalog")
            #expect(descriptor.targets.contains(target))
            #expect(!descriptor.cliName.isEmpty)
        }
    }
}
