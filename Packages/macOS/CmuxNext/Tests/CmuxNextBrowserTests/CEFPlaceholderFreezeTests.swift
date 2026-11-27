import AppKit
@testable import CmuxNextBrowser
import Foundation
import Testing

extension CEFSparePageSuites {
    /// The queued freeze follows the browser's navigation, not a host's adoptable-spare flag.
    @MainActor @Suite struct CEFPlaceholderFreezeTests {
        typealias Rig = CEFSparePageTests

        @MainActor final class Turns {
            var pending: [@MainActor @Sendable () -> Void] = []

            func run() {
                let callbacks = pending
                pending.removeAll()
                for callback in callbacks { callback() }
            }
        }

        static func placeholder(_ runtime: CEFRuntime, offTheRecord: Bool,
                                beforeAttach: ((CEFTab) -> Void)? = nil) throws -> (CEFSpareWindow, CEFTab, Turns) {
            let pool: CEFSpareWindow
            if offTheRecord {
                runtime.usePageSpareWindow(profile: .default)
                pool = try #require(runtime.pageSpareWindow)
            } else {
                pool = runtime.spareWindow
            }
            #expect(pool.prepare(runtime: runtime))
            let host = try #require(pool.host)
            let tab = try #require(host.placeholder)
            let request = try #require(runtime.pendingWindows.first { $0.value === host }?.key)
            let turns = Turns()
            host.endOfTurn = { turns.pending.append($0) }
            #expect(SpareSpy.createdURLs == [""], "normal and private placeholders have no initial navigation")
            beforeAttach?(tab)
            SpareSpy.windows[20] = 2
            runtime.handle(.afterCreated(browser: 20, request: request, window: 2))
            #expect(tab.browserID == 20)
            SpareSpy.clearRecords()
            return (pool, tab, turns)
        }

        static func tearDown(_ runtime: CEFRuntime, _ root: URL) {
            runtime.pageSpareWindow?.drop(runtime: runtime)
            Rig.tearDown(runtime, root)
        }

        static var freezes: [String] { SpareSpy.log.filter { $0.hasPrefix("freeze ") } }

        @Test(arguments: [false, true])
        func anEmptyPlaceholderFreezesWithoutLoadingEvents(offTheRecord: Bool) throws {
            let (runtime, root) = try Rig.runtime()
            defer { Self.tearDown(runtime, root) }
            let (_, tab, turns) = try Self.placeholder(runtime, offTheRecord: offTheRecord)
            #expect(tab.isLoadingSettled)
            #expect(Self.freezes.isEmpty)
            #expect(!turns.pending.isEmpty)
            turns.run()
            #expect(Self.freezes == ["freeze 20 devtools"])
            turns.run()
            runtime.handle(.loadingState(browser: 20, loading: false, canGoBack: false, canGoForward: false))
            #expect(Self.freezes == ["freeze 20 devtools"], "a redundant settled event does not refreeze")
        }

        @Test(arguments: [false, true])
        func aRequestedLoadRevokesEligibilityBeforeItsCallbacks(offTheRecord: Bool) throws {
            let (runtime, root) = try Rig.runtime()
            defer { Self.tearDown(runtime, root) }
            let (_, tab, turns) = try Self.placeholder(runtime, offTheRecord: offTheRecord)
            tab.load(Rig.address)
            #expect(!tab.isLoadingSettled)
            turns.run()
            #expect(Self.freezes.isEmpty, "the queued callback cannot freeze before loading(true) arrives")
            var stopped = 0
            tab.onLoadingStopped = { stopped += 1 }
            runtime.handle(.loadingState(browser: 20, loading: true, canGoBack: false, canGoForward: false))
            #expect(Self.freezes.isEmpty)
            runtime.handle(.loadingState(browser: 20, loading: false, canGoBack: false, canGoForward: false))
            #expect(stopped == 1)
            #expect(Self.freezes == ["freeze 20 devtools"])
            runtime.handle(.loadingState(browser: 20, loading: false, canGoBack: false, canGoForward: false))
            #expect(stopped == 1 && Self.freezes == ["freeze 20 devtools"])
        }

        @Test(arguments: [false, true])
        func aLoadRequestedDuringCreationIsNotAnEmptyDocument(offTheRecord: Bool) throws {
            let (runtime, root) = try Rig.runtime()
            defer { Self.tearDown(runtime, root) }
            let (_, tab, turns) = try Self.placeholder(runtime, offTheRecord: offTheRecord) { $0.load(Rig.address) }
            #expect(!tab.isLoadingSettled)
            turns.run()
            #expect(Self.freezes.isEmpty)
            runtime.handle(.loadingState(browser: 20, loading: true, canGoBack: false, canGoForward: false))
            runtime.handle(.loadingState(browser: 20, loading: false, canGoBack: false, canGoForward: false))
            #expect(tab.isLoadingSettled && Self.freezes == ["freeze 20 devtools"])
        }

        @Test(arguments: [false, true])
        func aChromiumLoadRevokesEmptyDocumentEligibility(offTheRecord: Bool) throws {
            let (runtime, root) = try Rig.runtime()
            defer { Self.tearDown(runtime, root) }
            let (_, tab, turns) = try Self.placeholder(runtime, offTheRecord: offTheRecord)
            runtime.handle(.loadingState(browser: 20, loading: true, canGoBack: false, canGoForward: false))
            turns.run()
            #expect(!tab.isLoadingSettled && Self.freezes.isEmpty)
            runtime.handle(.loadingState(browser: 20, loading: false, canGoBack: false, canGoForward: false))
            #expect(tab.isLoadingSettled && Self.freezes == ["freeze 20 devtools"])
        }

        @Test func adoptionBeforeTheQueuedFreezeDoesNotFreezeTheNewPage() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Self.tearDown(runtime, root) }
            let (pool, blank, turns) = try Self.placeholder(runtime, offTheRecord: true)
            let key = CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default, offTheRecord: true)
            let host = try #require(pool.take(for: key, runtime: runtime))
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            tab.load(Rig.address)
            host.add(tab)
            #expect(host.adoptPlaceholder(tab) == 20)
            #expect(SpareSpy.loads.map(\.url) == [Rig.address.absoluteString])
            #expect(blank.browserID == nil && !tab.isLoadingSettled)
            turns.run()
            #expect(Self.freezes.isEmpty, "the old placeholder callback cannot freeze the adopted browser")
            runtime.handle(.loadingState(browser: 20, loading: true, canGoBack: false, canGoForward: false))
            runtime.handle(.loadingState(browser: 20, loading: false, canGoBack: false, canGoForward: false))
            #expect(tab.isLoadingSettled && Self.freezes.isEmpty)
        }

        @Test func anEmptyHiddenDocumentDoesNotDependOnTheHostsPlaceholderFlag() throws {
            let (runtime, root) = try Rig.runtime()
            defer { Self.tearDown(runtime, root) }
            let (_, tab, turns) = try Self.placeholder(runtime, offTheRecord: false)
            defer { tab.host.placeholder = tab }
            tab.host.placeholder = nil
            #expect(!tab.host.adoptablePlaceholder && tab.host.visibleTab == nil)
            turns.run()
            #expect(tab.isLoadingSettled && Self.freezes.isEmpty)
            tab.load(Rig.address)
            #expect(!tab.isLoadingSettled)
        }

        @Test(arguments: ["about:blank", "https://example.com/"])
        func anExplicitInitialNavigationWaitsForLoadingStopped(address: String) throws {
            let (runtime, root) = try Rig.runtime()
            defer { Self.tearDown(runtime, root) }
            let host = CEFPaneHost(key: CEFPaneKey(pane: BrowserPaneID(rawValue: UUID().uuidString), profile: .default), runtime: runtime)
            let tab = CEFTab(id: .random(), profile: .default, host: host, runtime: runtime)
            tab.pendingURL = URL(string: address)
            #expect(tab.takeInitialURLString() == address)
            runtime.register(tab, browser: 20)
            #expect(!tab.isLoadingSettled, "an explicit URL is not a no-navigation creation")
            runtime.handle(.loadingState(browser: 20, loading: true, canGoBack: false, canGoForward: false))
            runtime.handle(.loadingState(browser: 20, loading: false, canGoBack: false, canGoForward: false))
            #expect(tab.isLoadingSettled)
        }
    }
}
