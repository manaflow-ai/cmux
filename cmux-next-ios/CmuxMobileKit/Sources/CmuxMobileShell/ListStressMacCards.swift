// DEBUG builds only: the list stress rig's mock Mac `tabs` records (`CMUX_MOBILE_LIST_MAC_CARDS=1`).
#if os(iOS) && DEBUG
import CmuxMobileModel
import CmuxMobileWorkspaces
import CryptoKit
import Foundation
import UIKit

/// What a Mac's `tabs` service pushes of the rig's tabs, handed to `MacTabCards` the way
/// `MacTabsCardSink` hands it the feed's rows and blobs: a favicon and a thumbnail for each
/// browser tab, a screen of text for each terminal. Agent tabs get no record (their card is
/// the phone's own picture, `TabCardSnapshots`). The rows and blobs are written to disk, so a
/// later launch without this setting opens cold and reads them from there.
@MainActor
enum ListStressMacCards {
    /// Waits for a signed-in account (the cache is keyed by it), seeds, then waits until the
    /// rows and every blob are on disk and tells the face probe.
    static func seed(tabs: [WorkspaceTab], macID: String, drops: Bool = false) async {
        for _ in 0 ..< 60 {
            if let account = TabCardSnapshots.shared.accountID?(), !account.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard let account = TabCardSnapshots.shared.accountID?(), !account.isEmpty else { return }
        let cards = MacTabCards.shared
        var rows: [(tabID: String, info: MacCardInfo)] = []
        var blobs: [(hash: String, bytes: Data)] = []
        func blob(_ bytes: Data) -> String {
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            blobs.append((hash, bytes))
            return hash
        }
        let now = Int64(Date().timeIntervalSince1970 * 1000)
        for (index, tab) in tabs.enumerated() {
            switch tab.kind {
            case .browser:
                rows.append((tab.id, MacCardInfo(title: tab.title, kind: "browser",
                                                 faviconHash: blob(png(size: CGSize(width: 32, height: 32), index: index)),
                                                 thumbHash: blob(png(size: CGSize(width: 354, height: 500), index: index)),
                                                 capturedAtMs: now)))
            case .terminal:
                let screen = "\(tab.title)\n$ git status\nOn branch main\nnothing to commit, working tree clean\n$ "
                rows.append((tab.id, MacCardInfo(title: tab.title, kind: "terminal", screenHash: blob(Data(screen.utf8)),
                                                 screenColumns: 60, screenRows: 5, capturedAtMs: now)))
            default:
                break
            }
        }
        let held = blobs, listed = rows
        for item in held { cards.save(item.bytes, hash: item.hash, macID: macID) }
        cards.cards(listed, macID: macID)
        // The writes are detached: done when the rows and every blob read back.
        let store = TabSnapshotStore.standard
        for _ in 0 ..< 40 {
            let onDisk = await Task.detached {
                store.macCards(accountID: account, macID: macID).count == listed.count
                    && held.allSatisfy { store.macBlob($0.hash, accountID: account, macID: macID) != nil }
            }.value
            if onDisk { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        TabCardFaceProbe.macSeeded(cards: listed.count)
        guard drops else { return }
        // A newer row of every tab with no picture, and the blobs no row names: what a Mac sends of
        // tabs it hibernated or after its daemon restarted.
        try? await Task.sleep(for: .seconds(4))
        let bare = listed.map { row in
            (tabID: row.tabID, info: MacCardInfo(title: "dropped-" + row.info.title, kind: row.info.kind,
                                                 capturedAtMs: row.info.capturedAtMs + 1000))
        }
        cards.cards(bare, macID: macID)
        cards.remove(blobs: held.map(\.hash), macID: macID)
        for _ in 0 ..< 40 {
            let onDisk = await Task.detached {
                let rows = store.macCards(accountID: account, macID: macID)
                return rows.count == bare.count && rows.values.allSatisfy { $0.title.hasPrefix("dropped-") }
            }.value
            if onDisk { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        TabCardFaceProbe.macDropped()
    }

    /// A flat colored picture, a different color for each tab.
    private static func png(size: CGSize, index: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor(hue: CGFloat(index % 12) / 12, saturation: 0.5, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
#endif
