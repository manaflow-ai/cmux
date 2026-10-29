#if os(iOS)
import CmuxMobileBrowserStream
import CmuxMobileModel
import CmuxMobileTransport
import CmuxTabsKit
import Foundation
import Testing
@testable import CmuxMobileWorkspaces

/// A Mac that streams browser tabs: each open records the tab and keeps its stream,
/// whose `rb.*` messages are what the phone asked the Mac to do.
private final class MacBrowser: BrowserStreamOpening, @unchecked Sendable {
    let lock = NSLock()
    private var sinks: [String: any BrowserStreamSink] = [:]
    private var streams: [String: Stream] = [:]

    func openBrowser(tab: String, url: String?, sink: any BrowserStreamSink) async throws -> any BrowserStreamConnection {
        let stream = Stream()
        lock.withLock {
            sinks[tab] = sink
            streams[tab] = stream
        }
        return stream
    }

    func sink(_ tab: String) -> (any BrowserStreamSink)? { lock.withLock { sinks[tab] } }
    func sent(_ tab: String) -> [[String: Any]] { lock.withLock { streams[tab]?.messages() ?? [] } }

    final class Stream: BrowserStreamConnection, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [[String: Any]] = []
        func send(message: Data) throws {
            let object = (try? JSONSerialization.jsonObject(with: message) as? [String: Any]) ?? [:]
            lock.withLock { sent.append(object) }
        }
        func send(input: Data, mustDeliver: Bool) throws {}
        func requestKeyframe() {}
        func noteDecode(micros: UInt32) {}
        func stats() -> BrowserStreamStats { BrowserStreamStats() }
        func nowMicros() -> UInt64 { 0 }
        func close() {}
        func messages() -> [[String: Any]] { lock.withLock { sent } }
    }
}

/// Open on iPhone / Mirror from <Mac> on a linked browser tab, through the tab
/// source the workspace screen drives (its page menu and its page).
@MainActor @Suite(.serialized) struct NativeBrowserTabTests {
    let tab = "t-docs"

    func defaults() -> UserDefaults {
        let name = "native-browser-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func until(_ check: () -> Bool) async {
        for _ in 0..<400 where !check() { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// The workspace `ws-cmux` linked to a Mac whose page for `t-docs` is at `macURL`.
    func linked(at macURL: String, native: NativeBrowserTabs) async throws
        -> (source: WorkspaceTabsSource, mac: MacBrowser, mirror: StreamedBrowserModel) {
        let store = AppStore.mock(tabMemory: .inMemory([:]))
        let directory = StreamedBrowserDirectory()
        let mac = MacBrowser()
        directory.opener = { mac }
        let source = WorkspaceTabsSource(store: store, workspaceID: "ws-cmux", native: native, streamed: directory)
        let docs = try #require(source.workspace?.tabs.first { $0.id == tab })
        let mirror = try #require(source.browser(docs) as? StreamedBrowserModel)
        mirror.setVisible(true)
        mirror.layout(points: CGSize(width: 402, height: 700), screenScale: 3)
        await until { mac.sink(tab) != nil }
        let sink = try #require(mac.sink(tab))
        sink.browserMessage(Data(#"{"t":"welcome","caps":[]}"#.utf8))
        sink.browserMessage(Data(#"{"t":"rb.page","url":"\#(macURL)","title":"Mac page","loading":false,"can_go_back":true,"can_go_forward":false}"#.utf8))
        await until { mirror.url?.absoluteString == macURL }
        return (source, mac, mirror)
    }

    func menuIDs(_ source: WorkspaceTabsSource) throws -> [String] {
        let kit = try #require(source.tabs.first { $0.id == tab })
        return source.pageMenu(for: kit).flatMap { $0.map(\.id) }
    }

    func page(_ source: WorkspaceTabsSource) throws -> any BrowserTabState {
        source.browser(try #require(source.workspace?.tabs.first { $0.id == tab }))
    }

    @Test func openOnIPhoneLoadsTheMacsPageAndMirroringCarriesWhereThePersonWent() async throws {
        let (source, mac, _) = try await linked(at: "https://example.com/mac", native: NativeBrowserTabs(defaults: defaults()))
        #expect(try menuIDs(source).contains("browser.openOnPhone"))

        source.openOnPhone(tab)
        let phone = try #require(try page(source) as? BrowserTabModel)
        #expect(phone.url?.absoluteString == "https://example.com/mac", "the phone opens at the Mac's current page")
        #expect(try menuIDs(source).contains("browser.mirrorFromMac"))
        #expect(!(try menuIDs(source).contains("browser.openOnPhone")))
        #expect(source.toastText?.contains("Sign-ins on") == true, "the person learns the Mac's sign-ins stay there")
        // The toolbar follows the phone's page.
        #expect(source.tabs.first { $0.id == tab }?.subtitle == "example.com")

        // The address bar navigates the phone's page, not the Mac's.
        source.navigate(tab, to: "example.org/phone")
        #expect(phone.url?.absoluteString == "https://example.org/phone")
        #expect(!mac.sent(tab).contains { $0["t"] as? String == "rb.navigate" })

        source.mirrorFromMac(tab)
        #expect(try page(source) is StreamedBrowserModel, "back on the Mac's page")
        let navigations = mac.sent(tab).filter { $0["t"] as? String == "rb.navigate" }
        #expect(navigations.map { $0["url"] as? String } == ["https://example.org/phone"],
                "the Mac's tab continues where the person was on the iPhone")
    }

    @Test func mirroringWithoutBrowsingLeavesTheMacsPageAlone() async throws {
        let (source, mac, _) = try await linked(at: "https://example.com/mac", native: NativeBrowserTabs(defaults: defaults()))
        source.openOnPhone(tab)
        source.mirrorFromMac(tab)
        #expect(!mac.sent(tab).contains { $0["t"] as? String == "rb.navigate" })
    }

    @Test func theMacsLocalhostStaysMirrored() async throws {
        let (source, _, _) = try await linked(at: "http://localhost:3000/", native: NativeBrowserTabs(defaults: defaults()))
        source.openOnPhone(tab)
        #expect(try page(source) is StreamedBrowserModel, "the phone's own localhost is not the Mac's")
        #expect(source.toastText == "localhost:3000 is on Aziz's Mac Studio. It can only be mirrored.")
    }

    @Test func aLocalhostLinkOnThePhoneAsksToMirror() async throws {
        let (source, mac, _) = try await linked(at: "https://example.com/mac", native: NativeBrowserTabs(defaults: defaults()))
        source.openOnPhone(tab)
        let phone = try #require(try page(source) as? BrowserTabModel)
        source.navigate(tab, to: "localhost:5173")
        #expect(phone.problem?.isMacOnly == true)
        #expect(phone.problem?.url.absoluteString == "http://localhost:5173")
        // The card's Mirror from <Mac>: the Mac opens what the phone could not.
        source.mirrorFromMac(tab)
        #expect(mac.sent(tab).filter { $0["t"] as? String == "rb.navigate" }.map { $0["url"] as? String } == ["http://localhost:5173"])
    }

    @Test func theChoiceStaysWithTheTabAcrossLaunchesUntilItCloses() async throws {
        let saved = defaults()
        let first = NativeBrowserTabs(defaults: saved)
        let (source, _, _) = try await linked(at: "https://example.com/mac", native: first)
        source.openOnPhone(tab)
        source.navigate(tab, to: "https://example.org/later")

        // The next launch: the tab opens on the iPhone where it was.
        let relaunched = NativeBrowserTabs(defaults: saved)
        #expect(relaunched.isNative(tab: tab, macID: "mac-studio"))
        #expect(relaunched.model(tab: tab, macID: "mac-studio")?.url?.absoluteString == "https://example.org/later")
        #expect(!relaunched.isNative(tab: "t-other", macID: "mac-studio"), "per tab, not every tab")

        relaunched.drop(tab: tab, macID: "mac-studio")
        #expect(!NativeBrowserTabs(defaults: saved).isNative(tab: tab, macID: "mac-studio"))
    }

    @Test(arguments: [
        ("https://example.com", PhoneReach.web),
        ("http://localhost:3000", .macOnly),
        ("http://app.localhost:8080", .macOnly),
        ("http://127.0.0.1:8000", .macOnly),
        ("http://[::1]:8000", .macOnly),
        ("file:///Users/me/index.html", .macOnly),
        ("view-source:https://example.com", .macOnly),
        ("http://mac-mini.tail137216.ts.net:3000", .privateNetwork),
        ("http://100.70.231.80:8080", .privateNetwork),
        ("http://192.168.1.20", .privateNetwork),
        ("http://studio.local:5000", .privateNetwork),
        ("http://devbox:8080", .privateNetwork),
        ("http://8.8.8.8", .web),
    ])
    func whereAnAddressPoints(_ address: String, _ reach: PhoneReach) {
        #expect(PhoneReach(URL(string: address)) == reach)
    }
}
#endif
