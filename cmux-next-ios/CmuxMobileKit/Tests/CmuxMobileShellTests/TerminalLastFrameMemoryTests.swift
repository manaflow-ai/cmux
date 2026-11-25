#if os(iOS)
import CmuxMobileModel
import CmuxMobileTerminal
import CmuxMobileWorkspaces
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileShell

/// A cooled terminal tab's last frame waits on disk (the JPEG `cool` writes), not in memory
/// (Leo, 2026-11-14: "I want us to also look at if we can decrease battery drain/ram on iOS app
/// and cc aziz too"). Before, every tab cooled out of the warm set kept a full-size `UIImage`
/// in `lastFrames` until it closed, with no cap and through memory warnings.
@MainActor @Suite(.serialized) struct TerminalLastFrameMemoryTests {
    static let account = "acct-frames"

    static func jpeg(_ index: Int) throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 600)).image { context in
            UIColor(white: CGFloat(index % 10) / 10, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 390, height: 600))
        }
        return try #require(image.jpegData(compressionQuality: 0.7))
    }

    /// One workspace of `count` terminal tabs, each with a frame on disk from an earlier launch.
    static func setUp(count: Int) throws -> (GhosttyTerminalTabContent, Workspace, TerminalFrameStore) {
        let content = GhosttyTerminalTabContent()
        let store = TerminalFrameStore(directory: FileManager.default.temporaryDirectory
            .appending(path: "terminal-frames-\(UUID().uuidString)"))
        content.frameStore = store
        content.accountUserIDProvider = { Self.account }
        content.sessionProvider = { _, _ in nil }
        content.hasLiveSession = { _, _ in false }
        var workspace = try #require(AppStore.mock().workspaces.first { !$0.macID.isEmpty })
        workspace.tabs = (0..<count).map { WorkspaceTab(id: "term-\($0)", kind: .terminal, title: "zsh \($0)") }
        for (index, tab) in workspace.tabs.enumerated() {
            store.save(try jpeg(index), for: TerminalFrameKey(accountID: account, macID: workspace.macID, surfaceID: tab.id))
        }
        return (content, workspace, store)
    }

    static func show(_ content: GhosttyTerminalTabContent, _ tab: WorkspaceTab, in workspace: Workspace) {
        _ = content.page(for: tab, in: workspace,
                         context: TerminalTabContext(safeAreaInsets: .init(), isInteractive: true,
                                                     isZoomGestureActive: false, reportScroll: { _ in }))
    }

    /// 16 tabs shown in turn: 12 are cooled out of the warm set of 4. None of their frames stays
    /// in memory, and a cooled tab shown again still shows its last frame at once (read back
    /// from disk) while it reattaches.
    @Test func cooledTabsKeepTheirFramesOnDiskNotInMemory() throws {
        let (content, workspace, _) = try Self.setUp(count: 16)
        defer { content.reset() }
        for tab in workspace.tabs { Self.show(content, tab, in: workspace) }
        print("terminal-frames: \(workspace.tabs.count - GhosttyTerminalTabContent.warmLimit) cooled tabs, \(content.framesHeldInMemory) frames in memory, \(content.frameBytesHeldInMemory) bytes")
        #expect(content.framesHeldInMemory == 0, "cooled tabs' frames are on disk")
        Self.show(content, workspace.tabs[0], in: workspace)
        let model = try #require(content.model(forTabID: workspace.tabs[0].id))
        #expect(model.coldFrame != nil, "a cooled tab shown again shows its last frame at once")
    }

    /// Without a frame store (nothing on disk), cooled frames stay in memory for the tabs'
    /// pages, and a memory warning lets them go.
    @Test func aMemoryWarningLetsInMemoryFramesGo() throws {
        let (content, workspace, _) = try Self.setUp(count: 10)
        defer { content.reset() }
        // Each host reads its frame from disk; then the store goes, so the cooled frames have
        // nowhere to wait but memory.
        for tab in workspace.tabs.prefix(GhosttyTerminalTabContent.warmLimit) { Self.show(content, tab, in: workspace) }
        content.frameStore = nil
        for tab in workspace.tabs.dropFirst(GhosttyTerminalTabContent.warmLimit) { Self.show(content, tab, in: workspace) }
        print("terminal-frames: without a frame store \(content.framesHeldInMemory) frames in memory")
        #expect(content.framesHeldInMemory > 0)
        MemoryPressure.shared.relieve()
        print("terminal-frames: after a memory warning \(content.framesHeldInMemory) frames in memory")
        #expect(content.framesHeldInMemory == 0, "a memory warning lets cooled frames go")
    }
}
#endif
