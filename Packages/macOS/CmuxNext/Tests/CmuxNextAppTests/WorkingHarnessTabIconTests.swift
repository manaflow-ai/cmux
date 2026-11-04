import AppKit
import CmuxNextBridge
@testable import CmuxNextDaemon
@testable import CmuxNextTabs
import Testing

/// Exercise the real harness artwork and mapping before checking the compact cell's layers.
@MainActor struct WorkingHarnessTabIconTests {
    enum Form: CaseIterable, Sendable {
        case narrow, pinned, titled

        var width: CGFloat {
            switch self {
            case .narrow: 32
            case .pinned: 44
            case .titled: 220
            }
        }
    }

    @Test(arguments: ["fox", "hammer", "zeta-bot", "claude-sr2", "claude", "unknown-harness"], Form.allCases)
    func workingKeepsHarnessArtwork(harness: String, form: Form) throws {
        let fixture = HarnessIconSurfacesTests()
        var item = TabItemMapping.shared.item(TabModel(HarnessIconSurfacesTests.chatSnapshot(harness)),
                                              fallbackTitle: "Chat", harnessIcons: fixture.icons)
        item.isPinned = form == .pinned
        item.indicator = .working(progress: nil)
        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: form.width, height: 32)
        cell.layoutLayers()
        let spinner = try #require(cell.spinnerLayer)
        #expect(cell.iconLayer.opacity == 1, "Working must not erase the harness identity")
        #expect(spinner.layer.opacity == 1)
        if form == .titled {
            #expect(spinner.frame.minX >= cell.iconLayer.frame.maxX)
        } else {
            #expect(!cell.visibility.showsTitle)
            #expect(spinner.frame.width < cell.iconLayer.bounds.width)
            #expect(spinner.frame.midX > cell.iconLayer.position.x)
            #expect(spinner.frame.midY > cell.iconLayer.position.y)
        }

        let iconFrame = cell.iconLayer.frame
        item.indicator = .idle
        cell.update(item: item)
        #expect(cell.iconLayer.opacity == 1)
        #expect(cell.iconLayer.frame == iconFrame, "Finishing work must not move the identity")
    }

    @Test(arguments: ["fox", "hammer"], [Form.narrow, .pinned])
    func browserLoadingStillReplacesItsArtwork(harness: String, form: Form) throws {
        // Favicons and user symbols share the same TabIcon cases as custom harnesses.
        var item = TabItem(id: TabID("browser"), title: "Page", icon: HarnessIconSurfacesTests().tabIcon(harness))
        item.isPinned = form == .pinned
        item.indicator = .busy(progress: nil)
        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: form.width, height: 32)
        cell.layoutLayers()
        let spinner = try #require(cell.spinnerLayer)
        #expect(cell.iconLayer.opacity == 0)
        #expect(spinner.layer.opacity == 1)
        #expect(spinner.frame.midX == cell.iconLayer.position.x)
        #expect(spinner.frame.midY == cell.iconLayer.position.y)
    }

    @Test func identityTintsTheHarnessWithoutMovingItAndUserTintWins() throws {
        var item = TabItem(id: TabID("subagent"), title: "Reviewer", icon: .agentMark("claude"))
        item.agentTone = 0
        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: 220, height: 32)
        cell.layoutLayers()
        let frame = cell.iconLayer.frame
        let first = try #require(cell.iconLayer.contents as? CGImage)
        item.agentTone = 1
        cell.update(item: item)
        let second = try #require(cell.iconLayer.contents as? CGImage)
        #expect(NSBitmapImageRep(cgImage: first).tiffRepresentation != NSBitmapImageRep(cgImage: second).tiffRepresentation)
        #expect(cell.iconLayer.frame == frame)
        item.tint = .red
        cell.update(item: item)
        let custom = try #require(cell.iconLayer.contents as? CGImage)
        item.agentTone = 2
        cell.update(item: item)
        #expect(cell.iconLayer.contents as? CGImage === custom, "the person's tab colour must win")
        #expect(cell.iconLayer.frame == frame)
    }

    @Test(arguments: ["Aleksandra Wiśniewska-Kowalczyk — release verification", "🦊 Fox", "王秀英的发布验证会话", "Đặng Thị Ngọc Hân", "J", ""])
    func worstCaseNamesDoNotMoveTheIdentityOrWorkingMark(title: String) throws {
        let fixture = HarnessIconSurfacesTests()
        var item = TabItemMapping.shared.item(TabModel(HarnessIconSurfacesTests.chatSnapshot("fox")),
                                              fallbackTitle: title, harnessIcons: fixture.icons)
        item.indicator = .working(progress: nil)
        let cell = TabCell(item: item)
        cell.frame = CGRect(x: 0, y: 0, width: 220, height: 32)
        cell.layoutLayers()
        let icon = cell.iconLayer.frame
        let spinner = try #require(cell.spinnerLayer).frame
        let visibleTitleWidth = try #require(cell.titleFade.geometry).visibleWidth
        #expect(cell.titleLayer.frame.minX + visibleTitleWidth <= spinner.minX)
        item.title = "Chat"
        cell.update(item: item)
        #expect(cell.iconLayer.frame == icon)
        #expect(cell.spinnerLayer?.frame == spinner)
        #expect(cell.titleFade.geometry?.visibleWidth == visibleTitleWidth)
        #expect(cell.iconLayer.opacity == 1)
    }
}
