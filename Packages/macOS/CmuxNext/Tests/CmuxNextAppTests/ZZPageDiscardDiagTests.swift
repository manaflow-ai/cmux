import AppKit
@testable import CmuxNextApp
@testable import CmuxNextBrowser
import Foundation
import Testing

// DIAGNOSTIC ONLY (never lands): prints the facts behind the three base reds of cp/fix-tip-page-discard.
@MainActor @Suite(.serialized) struct ZZPageDiscardDiagTests {
    @Test func zzTableFacts() {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        for offset in [CGFloat(0), 400] {
            let made = InternalPageDiscardPolicyCoverageTests.scrolledTable(count: 50, offset: offset)
            let scroll = made.container.subviews.first as? NSScrollView
            let table = scroll?.documentView as? NSTableView
            let clip = scroll?.contentView
            print("DIAG table os=\(os) offset=\(offset) style=\(table?.style.rawValue ?? -1) effective=\(table?.effectiveStyle.rawValue ?? -1)"
                  + " row0=\(table.map { NSStringFromRect($0.rect(ofRow: 0)) } ?? "-") row20=\(table.map { NSStringFromRect($0.rect(ofRow: 20)) } ?? "-")"
                  + " clipBounds=\(clip.map { NSStringFromRect($0.bounds) } ?? "-") insets=\(clip.map { "\($0.contentInsets)" } ?? "-")"
                  + " auto=\(scroll?.automaticallyAdjustsContentInsets ?? false) tableFrame=\(table.map { NSStringFromRect($0.frame) } ?? "-")"
                  + " rowAt0=\(table?.row(at: NSPoint(x: 0, y: 0)) ?? -9) rowAtOffset=\(table?.row(at: NSPoint(x: 0, y: offset)) ?? -9)"
                  + " rowAtMid=\(table?.row(at: NSPoint(x: 150, y: offset)) ?? -9)")
            withExtendedLifetime(made.rows) {}
        }
    }

    @Test func zzHistoryListFacts() {
        let rows = InternalPageDiscardPolicyCoverageTestsBatch2.TableRows()
        let scroll = InternalPageDiscardPolicyCoverageTestsBatch2.scrollingList(rows)
        let table = scroll.documentView as? NSTableView
        print("DIAG history auto=\(scroll.automaticallyAdjustsContentInsets) insets=\(scroll.contentView.contentInsets)"
              + " visible=\(NSStringFromRect(scroll.documentVisibleRect)) header=\(table?.headerView.map { NSStringFromRect($0.frame) } ?? "nil")"
              + " style=\(table?.style.rawValue ?? -1) effective=\(table?.effectiveStyle.rawValue ?? -1) clip=\(NSStringFromRect(scroll.contentView.bounds))")
        withExtendedLifetime(rows) {}
    }

    @Test func zzSnapshotFacts() throws {
        let rig = try HiddenPageHibernationTests.Rig()
        defer { rig.close() }
        rig.hibernation.discardsStreamedPages = true
        let snapshots = rig.hibernation.snapshots
        print("DIAG snapshot full=\(snapshots.fullCapacityBytes) capacity=\(snapshots.capacityBytes) keepsX=\(snapshots.keeps("x"))"
              + " compressed=\(snapshots.keepsCompressed) imageCacheBytes=\(rig.services.cache.imageCaches.hibernationSnapshotBytes)")
    }
}
