import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

extension CEFSparePageSuites {
    /// A link opened on the right has a stand-in tab: its page is made once the key's frame committed
    /// (`TabContentCache.browser(for:)`), which takes the spare Chromium window and shows the tab, and the tab's
    /// browser waited for another after-commit pass (`CEFPaneHost.createAfterCommit`). That pass is the main run
    /// loop's next idle one, which a busy main thread holds back: `tab_add` started 35 ms after the spare window's
    /// take at idle, 84 ms on a cold launch and 246 ms under load (medians, instant-new-surfaces link_right, fleet
    /// step d45296d5). Work that runs after the frame committed (`CEFRuntime.afterFrameCommitted`) is already past
    /// that commit: a tab it shows gets its browser at the end of that work, in the same pass.
    /// The stand-in shim and helpers are `CEFSparePageTests`' (`CEFSparePageFixture.swift`).
    @MainActor @Suite struct CEFAfterFrameCreationTests {
        typealias Rig = CEFSparePageTests

        @Test func aTabShownInAfterFrameWorkGetsItsBrowserWhenThatWorkEnds() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            Rig.setSparePage(false)
            let (host, _, container) = try Rig.liveHost(runtime)
            SpareSpy.clearRecords()
            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            runtime.afterFrameCommitted {
                host.present(link, in: container)
                #expect(SpareSpy.added.isEmpty, "never inside the work that showed it")
            }
            #expect(SpareSpy.added.map(\.anchor) == [10], "its browser joined the live window when the work ended")
            #expect(link.browserID != nil)
        }

        /// The spare window can be taken while Chromium still builds it. A tab shown then in after-frame work must not
        /// queue on that window: queued, it joins inside the window's OnAfterCreated (`windowCreated`), where its
        /// `tab_add` did nothing on the real fork (0 ms, no commit, no page in 5 s: instant-new-surfaces link_right, one
        /// cold launch of 51 with the first cut of this change, none of 85 without it). It waits for the frame's commit
        /// as before, and joins the live window outside Chromium's creation stack.
        @Test func aTabShownInAfterFrameWorkInAWindowStillBeingBuiltWaitsForTheCommitNotTheWindowsCreation() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            Rig.setSparePage(false)
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            host.endOfTurn = { $0() }
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
            let first = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(first)
            host.present(first, in: container)
            host.createDeferred()
            #expect(host.isCreatingWindow, "Chromium builds the window")
            let request = try #require(runtime.pendingWindows.keys.first)
            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            runtime.afterFrameCommitted { host.present(link, in: container) }
            SpareSpy.windows[10] = 1
            runtime.handle(.afterCreated(browser: 10, request: request, window: 1))
            #expect(SpareSpy.added.isEmpty, "no tab_add inside the window's OnAfterCreated")
            host.createDeferred()
            #expect(SpareSpy.added.map(\.anchor) == [10], "it joins the live window after the frame's commit")
            #expect(link.browserID != nil)
        }

        @Test func aTabShownOutsideAfterFrameWorkStillWaitsForTheFramesCommit() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Rig.tearDown(runtime, root) }
            Rig.setSparePage(false)
            let (host, _, container) = try Rig.liveHost(runtime)
            SpareSpy.clearRecords()
            let link = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            host.add(link)
            host.present(link, in: container)
            #expect(SpareSpy.added.isEmpty, "a tab shown in a key's turn gets its browser after that turn's frame")
            host.createDeferred()
            #expect(SpareSpy.added.map(\.anchor) == [10])
        }
    }
}
