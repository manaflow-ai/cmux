#if os(iOS)
import CmuxMobileModel
// `WorkspaceTabsSource.snapshots` is internal.
@testable import CmuxMobileWorkspaces
import Foundation
import SwiftUI
import Testing
import UIKit
@testable import CmuxMobileShell

/// A terminal card reads its last-known picture from the store its tabs source keeps pictures in,
/// not from `TabCardSnapshots.shared` behind the source's back: the picture kept when a tab is
/// left (`WorkspaceTabsSource.keepPicture`) is the one its card draws (Leo, 2026-11-24: "there
/// are too many empty previews in the safari grid thing we ought to be able to simply capture
/// them before they get hibernated maybe").
@MainActor @Suite(.serialized) struct TerminalCardPictureStoreTests {
    static func snapshots() -> TabCardSnapshots {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tab-snapshots-\(UUID().uuidString)", isDirectory: true)
        let snapshots = TabCardSnapshots(store: TabSnapshotStore(directory: directory),
                                         memoryPressure: MemoryPressure(observesSystem: false))
        snapshots.accountID = { "user-1" }
        return snapshots
    }

    /// Striped: a picture of one solid colour is a placeholder (`CardPictureGate`), never kept.
    static func picture() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 40, height: 56), format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 56))
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 10, height: 56))
        }
    }

    @Test func theTerminalCardsReadTheSourcesStore() throws {
        let content = GhosttyTerminalTabContent()
        content.frameStore = nil
        let store = AppStore.mock(tabMemory: .inMemory())
        store.workspaces.append(Workspace(id: "ws-store", macID: "mac-1", title: "Store", directory: "~",
                                          tabs: [WorkspaceTab(id: "term1", kind: .terminal, title: "zsh")], lastActivityAt: Date()))
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-store", terminal: content)
        let own = Self.snapshots()

        source.snapshots = own

        #expect(content.snapshots === own, "the source hands the terminal cards its store")
        let key = try #require(own.key(macID: "mac-1", tabID: "term1"))
        let image = Self.picture()
        own.put(image, for: key)
        #expect(TerminalTabSlotCard.lastKnown(in: content.snapshots, macID: "mac-1", tabID: "term1") === image,
                "the card reads the picture kept in the source's store")
        #expect(TerminalTabSlotCard.lastKnown(in: content.snapshots, macID: nil, tabID: "term1") == nil)

        // Handed back the shared store, the terminal reads that one again.
        source.snapshots = .shared
        #expect(content.snapshots === TabCardSnapshots.shared)
    }
}
#endif
