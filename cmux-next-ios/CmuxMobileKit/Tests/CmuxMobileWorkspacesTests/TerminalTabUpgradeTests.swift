import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// design/terminal R1-0: a terminal page built before live data (a launch
/// restore) moves to its live session once the tree lists its surface.
@Suite struct TerminalTabUpgradeTests {
    @Test func restoredPlaceholderIsOfferedItsLiveSession() {
        var upgrade = TerminalTabUpgrade()
        // Cold launch: the restore opens the workspace before the tree exists.
        upgrade.built(tabID: "t1", workspaceID: "w1", live: false)
        var tree: Set<String> = []
        #expect(upgrade.upgradable { tree.contains($0) }.isEmpty)
        // The link comes up and the tree lists the tab's surface.
        tree = ["t1"]
        #expect(upgrade.upgradable { tree.contains($0) } == ["t1"])
        // Upgraded: the live host is built; nothing is offered again.
        upgrade.built(tabID: "t1", workspaceID: "w1", live: true)
        #expect(upgrade.upgradable { tree.contains($0) }.isEmpty)
    }

    @Test func liveTabsAndClosedTabsAreNotOffered() {
        var upgrade = TerminalTabUpgrade()
        upgrade.built(tabID: "a", workspaceID: "w", live: true)
        upgrade.built(tabID: "b", workspaceID: "w", live: false)
        upgrade.built(tabID: "c", workspaceID: "w", live: false)
        upgrade.removed(tabID: "c")
        #expect(upgrade.upgradable { _ in true } == ["b"])
        upgrade.reset()
        #expect(upgrade.upgradable { _ in true }.isEmpty)
    }

    @Test func lastFramesSurviveARelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TerminalFrameStore(directory: dir)
        let key = TerminalFrameKey(accountID: "account-a", macID: "mac-a", surfaceID: "s/12:tab")
        store.save(Data([1, 2, 3]), for: key)
        // A new store (a new launch) reads it back; the scoped key is a safe file name.
        #expect(TerminalFrameStore(directory: dir).load(key) == Data([1, 2, 3]))
        #expect(store.url(for: key).lastPathComponent.hasPrefix("v1-"))
        store.remove(key)
        #expect(store.load(key) == nil)
    }

    @Test func cooledFrameNeverCrossesMacsAcrossRelaunch() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TerminalFrameStore(directory: dir)
        let account = "account-a"
        let macA = TerminalFrameKey(accountID: account, macID: "mac-a", surfaceID: "s1")
        let macB = TerminalFrameKey(accountID: account, macID: "mac-b", surfaceID: "s1")
        let frameA = Data([0xA1])

        // Model Ghostty's four-host warm set: visiting four newer A surfaces
        // cools A/s1 and persists its last frame.
        var warm: [TerminalFrameKey] = []
        var lastFrames: [TerminalFrameKey: Data] = [:]
        func visit(_ key: TerminalFrameKey, frame: Data) {
            warm.removeAll { $0 == key }
            warm.append(key)
            lastFrames[key] = frame
            if warm.count > 4, let cooled = warm.first {
                warm.removeFirst()
                if let frame = lastFrames.removeValue(forKey: cooled) { store.save(frame, for: cooled) }
            }
        }
        visit(macA, frame: frameA)
        for index in 2...5 {
            visit(TerminalFrameKey(accountID: account, macID: "mac-a", surfaceID: "s\(index)"), frame: Data([UInt8(index)]))
        }
        #expect(lastFrames[macA] == nil)
        #expect(store.load(macA) == frameA)
        // A pre-fix, unscoped entry cannot be assigned to either Mac.
        try Data([0xFF]).write(to: dir.appendingPathComponent("s1.jpg"))
        // Mac B opens its same-numbered tab before live output arrives.
        #expect(store.load(macB) == nil)
        #expect(store.load(macA) == frameA)

        // A relaunch keeps A's frame for A and never assigns it to B.
        let relaunched = TerminalFrameStore(directory: dir)
        #expect(relaunched.load(macB) == nil)
        #expect(relaunched.load(macA) == frameA)
    }

    /// Round 11 A5: a frame rendered off the main thread and written late
    /// must not replace a newer frame, nor bring back a closed tab's file.
    @Test func aLateFrameNeverReplacesANewerOneOrAClosedTab() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TerminalFrameStore(directory: dir)
        let key = TerminalFrameKey(accountID: "account-a", macID: "mac-a", surfaceID: "t")
        let old = store.ticket(for: key)
        store.save(Data([2]), for: key)  // a newer frame, written at once (going to the background)
        store.save(Data([1]), for: key, ticket: old)
        #expect(store.load(key) == Data([2]))
        let late = store.ticket(for: key)
        store.remove(key)  // the tab closed
        store.save(Data([3]), for: key, ticket: late)
        #expect(store.load(key) == nil)
        let next = store.ticket(for: key)
        store.save(Data([4]), for: key, ticket: next)
        #expect(store.load(key) == Data([4]))
    }

    /// A cooled tab keeps its identity until release so closing it removes both
    /// the in-memory preview and its persisted frame.
    @Test func cooledFrameIsRemovedWhenTabReleases() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("frames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = TerminalFrameStore(directory: dir)
        let key = TerminalFrameKey(accountID: "account-a", macID: "mac-a", surfaceID: "s1")
        var lastFrames = [key: Data([1, 2, 3])]
        store.save(Data([1, 2, 3]), for: key)

        var lifecycle = TerminalFrameLifecycle()
        lifecycle.cooled(tabID: "tab", frameKey: key)
        lifecycle.release(tabID: "tab", hostFrameKey: nil) { releasedKey in
            lastFrames[releasedKey] = nil
            store.remove(releasedKey)
        }

        #expect(lastFrames[key] == nil)
        #expect(store.load(key) == nil)
    }

    @Test func rewarmedTabReleasesOnlyItsCurrentFrame() {
        let oldKey = TerminalFrameKey(accountID: "account-a", macID: "mac-a", surfaceID: "s1")
        let currentKey = TerminalFrameKey(accountID: "account-a", macID: "mac-b", surfaceID: "s1")
        var lifecycle = TerminalFrameLifecycle()
        lifecycle.cooled(tabID: "tab", frameKey: oldKey)
        lifecycle.hostBuilt(tabID: "tab")
        var removed: [TerminalFrameKey] = []
        lifecycle.release(tabID: "tab", hostFrameKey: currentKey) { removed.append($0) }
        #expect(removed == [currentKey])
        lifecycle.release(tabID: "tab", hostFrameKey: nil) { removed.append($0) }
        #expect(removed == [currentKey])
    }

    @Test func resetForgetsCooledFrameIdentity() {
        let key = TerminalFrameKey(accountID: "account-a", macID: "mac-a", surfaceID: "s1")
        var lifecycle = TerminalFrameLifecycle()
        lifecycle.cooled(tabID: "tab", frameKey: key)
        lifecycle.reset()
        lifecycle.release(tabID: "tab", hostFrameKey: nil) { _ in
            Issue.record("Reset must not retain another account's cooled identity")
        }
    }
}
