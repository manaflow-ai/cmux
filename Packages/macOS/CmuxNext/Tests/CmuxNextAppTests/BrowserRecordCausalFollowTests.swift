import AppKit
@testable import CmuxNextApp
import CmuxNextBrowser
import CmuxNextBrowserHistory
@testable import CmuxNextDaemon
import Foundation
import Testing

/// A page whose URL changes on every pan (Google Maps) writes each address to
/// its daemon record. The daemon publishes the record before it answers, but
/// the store applies that event only after the reply reaches the app. The
/// page follows another client's address (`workspace.open_url` reusing the
/// tab); its own writes, seen late, must never count as another client's, or
/// the page reloads at a viewport it already left.
@MainActor
@Suite(.serialized)
struct BrowserRecordCausalFollowTests {
    final class Daemon {
        /// Every address the page wrote, in order.
        var writes: [String] = []
        /// Record addresses the daemon published that the store has not applied yet.
        var unapplied: [String] = []
        /// Another client's address the daemon commits right after the page's next write.
        var foreignAfterNextWrite: String?
    }

    static let a = URL(string: "https://www.google.com/maps/@1,1,10z")!
    static let b = URL(string: "https://www.google.com/maps/@2,2,10z")!
    static let c = URL(string: "https://www.google.com/maps/@3,3,10z")!
    static let opened = URL(string: "https://example.com/opened")!

    /// A frontend browser tab showing `a`, tracked with no write-back delay.
    /// `settled` applies what the daemon published, one record at a time.
    static func tracked(_ daemon: Daemon) -> (BrowserTabService, MockBrowserTab, TabModel) {
        let service = BrowserTabService(daemon: DaemonService(), cef: CEFEngine(layout: nil, stores: .inMemory(), signInCallbacks: CEFSignInCallbacks()))
        let tab = TabModel(TabSnapshot(surface: SurfaceID(rawValue: 7), kind: .browser, url: a.absoluteString,
                                       browserRenderer: "frontend", browserEngine: "cef"))
        service.tabModel = { $0 == tab.id ? tab : nil }
        service.writeBackDelay = .zero
        service.sleep = { _ in }
        service.update = { _, _, update in
            if let url = update.url {
                daemon.writes.append(url)
                daemon.unapplied.append(url)
                if let foreign = daemon.foreignAfterNextWrite {
                    daemon.unapplied.append(foreign)
                    daemon.foreignAfterNextWrite = nil
                }
            }
            return true
        }
        service.settled = { _ in
            while !daemon.unapplied.isEmpty {
                tab.url = daemon.unapplied.removeFirst()
                for _ in 0..<3 { await Task.yield() }
            }
        }
        service.fetchHistory = { _, _ in nil }
        service.storeHistory = { _, _, _ in true }
        let page = MockBrowserEngine(kind: .cef).makeMockTab(BrowserTabConfiguration(initialURL: a))
        service.track(page, for: tab)
        return (service, page, tab)
    }

    static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    static func loads(_ page: MockBrowserTab) -> [URL] {
        page.commands.compactMap { if case .load(let url) = $0 { url } else { nil } }
    }

    /// The store applies, one at a time, any record the daemon published that
    /// is still unapplied, waiting each time for the writer to see it.
    static func applyLate(_ daemon: Daemon, _ tab: TabModel, _ writer: BrowserRecordWriter, _ page: MockBrowserTab) async throws {
        while !daemon.unapplied.isEmpty {
            let url = daemon.unapplied.removeFirst()
            let before = loads(page)
            tab.url = url
            try await until { writer.recorded.url == url || loads(page) != before }
        }
    }

    @Test func thePagesOwnWritesSeenLateNeverReloadIt() async throws {
        let daemon = Daemon()
        let (service, page, tab) = Self.tracked(daemon)
        let writer = try #require(service.writers[tab.id])
        let initial = Self.loads(page)

        // The map pans twice; each address is written and answered.
        page.simulate(.urlChanged(Self.b))
        try await Self.until { daemon.writes.last == Self.b.absoluteString }
        page.simulate(.urlChanged(Self.c))
        try await Self.until { daemon.writes.last == Self.c.absoluteString && writer.recorded.url == Self.c.absoluteString }
        // Whatever the store has not applied yet arrives now, oldest first.
        try await Self.applyLate(daemon, tab, writer, page)

        #expect(Self.loads(page) == initial, "the page reloaded at an address it had already left")
        #expect(page.state.url == Self.c)
        writer.cancel()
    }

    @Test func anotherClientsAddressRightAfterThePagesWriteLoads() async throws {
        let daemon = Daemon()
        let (service, page, tab) = Self.tracked(daemon)
        let writer = try #require(service.writers[tab.id])
        let initial = Self.loads(page)

        // `workspace.open_url` reuses the tab just after the page wrote `b`.
        daemon.foreignAfterNextWrite = Self.opened.absoluteString
        page.simulate(.urlChanged(Self.b))
        try await Self.until { daemon.writes.last == Self.b.absoluteString }
        try await Self.until { Self.loads(page).last == Self.opened || daemon.unapplied.count == 2 }
        try await Self.applyLate(daemon, tab, writer, page)

        #expect(Self.loads(page) == initial + [Self.opened], "the page loaded its own old address or missed the opened one")
        writer.cancel()
    }

    @Test func anotherClientsAddressLoadsWhenThePageIsIdle() async throws {
        let daemon = Daemon()
        let (service, page, tab) = Self.tracked(daemon)
        let writer = try #require(service.writers[tab.id])

        page.simulate(.urlChanged(Self.b))
        try await Self.until { daemon.writes.last == Self.b.absoluteString && writer.recorded.url == Self.b.absoluteString }
        try await Self.applyLate(daemon, tab, writer, page)

        tab.url = Self.opened.absoluteString
        try await Self.until { Self.loads(page).last == Self.opened }
        #expect(Self.loads(page).last == Self.opened)
        writer.cancel()
    }
}
