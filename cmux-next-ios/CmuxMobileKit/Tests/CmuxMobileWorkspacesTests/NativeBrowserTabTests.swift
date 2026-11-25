#if os(iOS)
import CmuxMobileBrowserStream
import CmuxMobileModel
import CmuxMobileTransport
import CmuxTabsKit
import Darwin
import Foundation
import Testing
import UIKit
import WebKit
@testable import CmuxMobileWorkspaces

/// A Mac that streams browser tabs: each open records the tab and keeps its stream,
/// whose `rb.*` messages are what the phone asked the Mac to do.
final class MacBrowser: BrowserStreamOpening, @unchecked Sendable {
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

/// How many connections the Mac's dev server took.
final class ServedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func note() { lock.withLock { value += 1 } }
    var count: Int { lock.withLock { value } }
}

/// One `localhost` connection to a dev server on the Mac: each request gets `page`.
final class DevServerChannel: LinkChannel, @unchecked Sendable {
    let id: UInt32 = 1
    private let lock = NSLock()
    private var request = Data()
    private let page: String
    private let replies: AsyncStream<Data>.Continuation
    private var iterator: AsyncStream<Data>.Iterator

    init(page: String) {
        self.page = page
        let (stream, replies) = AsyncStream<Data>.makeStream()
        self.replies = replies
        iterator = stream.makeAsyncIterator()
    }

    func send(_ data: Data) async throws {
        let answers: Int = lock.withLock {
            request.append(data)
            var count = 0
            while let end = request.range(of: Data("\r\n\r\n".utf8)) {
                request.removeSubrange(..<end.upperBound)
                count += 1
            }
            return count
        }
        for _ in 0..<answers {
            replies.yield(Data("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: \(page.utf8.count)\r\n\r\n\(page)".utf8))
        }
    }

    func receive() async throws -> Data? {
        var next = lock.withLock { iterator }
        let data = await next.next()
        lock.withLock { iterator = next }
        return data
    }

    func close(code: String, reason: String) async { replies.finish() }
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

    /// A page that moves by itself on the phone (a mobile site, a sign-in page for a phone
    /// with no session) never moves the Mac's page.
    @Test func aRedirectThePhoneTookByItselfIsNotCarried() async throws {
        let (source, mac, _) = try await linked(at: "https://example.com/mac", native: NativeBrowserTabs(defaults: defaults()))
        source.openOnPhone(tab)
        let phone = try #require(try page(source) as? BrowserTabModel)
        phone.load(try #require(URL(string: "https://accounts.example.com/signin?continue=mac")))
        source.mirrorFromMac(tab)
        #expect(try page(source) is StreamedBrowserModel)
        #expect(!mac.sent(tab).contains { $0["t"] as? String == "rb.navigate" })
    }

    /// Back from the "is on <Mac>" card shows the page under it, on the phone.
    @Test func backFromARefusedAddressShowsThePageUnderIt() async throws {
        let (source, _, _) = try await linked(at: "https://example.com/mac", native: NativeBrowserTabs(defaults: defaults()))
        var left = false
        source.exit = { left = true }
        source.openOnPhone(tab)
        let phone = try #require(try page(source) as? BrowserTabModel)
        source.navigate(tab, to: "localhost:5173")
        #expect(phone.problem != nil && phone.canGoBack)
        source.goBack(tab)
        #expect(phone.problem == nil)
        #expect(phone.url?.host() != "localhost")
        #expect(!left, "Back clears the card; it does not leave the workspace")
        #expect(try page(source) is BrowserTabModel)
    }

    /// Unlinked, there is no mirror to go back to: the page stays on the phone.
    @Test func withoutALinkThePageStaysOnThePhone() async throws {
        let native = NativeBrowserTabs(defaults: defaults())
        let (source, _, _) = try await linked(at: "https://example.com/mac", native: native)
        source.openOnPhone(tab)
        source.streamed.opener = nil
        source.mirrorFromMac(tab)
        #expect(native.isNative(tab: tab, macID: "mac-studio"))
        #expect(!(try menuIDs(source).contains("browser.mirrorFromMac")))
    }

    /// Tabs closed on the Mac lose their phone page; a placeholder tab that became real keeps it.
    @Test func phonePagesFollowTheMacsTabList() {
        let native = NativeBrowserTabs(defaults: defaults())
        native.open(tab: "pending-1", macID: "mac-studio", at: URL(string: "https://example.com"))
        native.open(tab: "s9", macID: "mac-studio", at: URL(string: "https://example.org"))
        native.rename(tab: "pending-1", to: "s12")
        #expect(native.isNative(tab: "s12", macID: "mac-studio") && !native.isNative(tab: "pending-1", macID: "mac-studio"))
        native.retain(tabs: ["s12"])
        #expect(native.isNative(tab: "s12", macID: "mac-studio"))
        #expect(!native.isNative(tab: "s9", macID: "mac-studio"))
    }

    @Test func theMacsLocalhostStaysMirrored() async throws {
        let (source, _, _) = try await linked(at: "http://localhost:3000/", native: NativeBrowserTabs(defaults: defaults()))
        source.openOnPhone(tab)
        #expect(try page(source) is StreamedBrowserModel, "the phone's own localhost is not the Mac's")
        #expect(source.toastText == "localhost:3000 is on Aziz's Mac Studio. It can only be mirrored.")
    }

    /// A Mac that serves `localhost`: its dev server's page loads in the phone's own
    /// web view through this iPhone's listener on the same port, and mirroring back
    /// stops the listener.
    @Test func aMacThatForwardsOpensItsLocalhostPageOnThePhone() async throws {
        let served = ServedRequests()
        let native = NativeBrowserTabs(defaults: defaults())
        native.forwarder = LocalhostForwarder { _, _ in
            served.note()
            return DevServerChannel(page: "<!doctype html><title>Forwarded from the Mac</title><p>dev server")
        }
        native.macForwardsLocalhost = { $0 == "mac-studio" }
        await Self.warmWebKit()
        // 127.0.0.1: the test runner has no App Transport Security exception for `localhost`.
        let port = try freePort()
        let (source, _, _) = try await linked(at: "http://127.0.0.1:\(port)/", native: native)
        source.openOnPhone(tab)
        let phone = try #require(try page(source) as? BrowserTabModel, "the Mac's localhost opens on the phone")
        // On screen, as the tab's page is in the app (`BrowserPage`). WebKit treats a web view in
        // no window as hidden and lets a busy simulator hold back its page's process, so in a
        // full kit run the page sometimes never parsed (no title) and the typed address below
        // never reached the navigation policy (its port never opened).
        let window = UIWindow(frame: phone.webView.frame)
        window.addSubview(phone.webView)
        window.isHidden = false
        defer { window.isHidden = true }
        for _ in 0..<2000 where phone.title != "Forwarded from the Mac" { try await Task.sleep(for: .milliseconds(5)) }
        #expect(phone.title == "Forwarded from the Mac",
                "the page came over the link: \(String(describing: phone.problem)), loading \(phone.isLoading) at \(phone.progress), \(served.count) served")
        #expect(served.count > 0)
        #expect(native.forwarder?.ports == [port])

        // Typed as people type it: no scheme, no slash (WebKit asks for `.../`).
        let typed = try freePort()
        source.navigate(tab, to: "127.0.0.1:\(typed)")
        for _ in 0..<2000 where native.forwarder?.ports.contains(typed) != true { try await Task.sleep(for: .milliseconds(5)) }
        #expect(native.forwarder?.ports.contains(typed) == true, "a typed address opens its port: \(String(describing: phone.problem))")
        #expect(phone.problem?.detail?.contains("A page tried") != true)

        source.mirrorFromMac(tab)
        #expect(native.forwarder?.ports.isEmpty == true, "no tab on the phone shows the port any more")
    }

    /// One port, one Mac: while one Mac's tab on this iPhone shows localhost:<port>,
    /// another Mac's tab can't take that port (its page would reach the wrong Mac).
    @Test func aPortShownForOneMacIsNotTakenByAnother() async throws {
        let native = NativeBrowserTabs(defaults: defaults())
        native.forwarder = LocalhostForwarder { _, _ in DevServerChannel(page: "x") }
        native.macForwardsLocalhost = { _ in true }
        let port = try freePort()
        native.open(tab: "s1", macID: "mac-a", at: URL(string: "http://127.0.0.1:\(port)/"))
        // Mac A's tab holds the port once WebKit asked for it.
        for _ in 0..<1000 where native.forwarder?.ports.contains(port) != true { try await Task.sleep(for: .milliseconds(5)) }
        let other = native.open(tab: "s2", macID: "mac-b", at: URL(string: "http://127.0.0.1:\(port)/"))
        #expect(other.problem?.isMacOnly == true)
        #expect(other.problem?.detail?.contains("Another Mac's tab") == true)
        native.drop(tab: "s1", macID: "mac-a")
        native.drop(tab: "s2", macID: "mac-b")
    }

    /// WebKit's first page in a freshly booted simulator waits for its web content and
    /// networking processes to launch, which on a busy fleet Mac took longer than this
    /// suite's 10 s waits: run alone, the forwarding test saw no navigation at all (no
    /// port, no request served, no problem). One local page loaded first takes that launch
    /// out of what the waits measure. It needs no network and no forwarder.
    static func warmWebKit() async {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        web.loadHTMLString("<!doctype html><title>warm</title>", baseURL: nil)
        // test: the launch has no completion to await; bounded so a broken WebKit fails the test below.
        for _ in 0..<12_000 where web.title != "warm" { try? await Task.sleep(for: .milliseconds(5)) }
    }

    /// A port nothing on this machine listens on (the simulator shares the host's loopback):
    /// the kernel's pick for a socket bound to `127.0.0.1:0`. The socket never listens and
    /// is closed before this returns, so the port is free at once. A probe listener freed
    /// its port only when its cancel finished, after `stop` returned, so the tab's own bind
    /// of that port sometimes failed as in use ("Another app on this iPhone uses port …").
    func freePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = in_addr_t(UInt32(0x7f00_0001).bigEndian)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0
            }
        }
        guard bound else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return UInt16(bigEndian: address.sin_port)
    }

    /// A Mac from before `localhost-forward-v1`: its localhost stays mirrored.
    @Test func anOlderMacsLocalhostStaysMirrored() async throws {
        let native = NativeBrowserTabs(defaults: defaults())
        native.forwarder = LocalhostForwarder { _, _ in throw CancellationError() }
        native.macForwardsLocalhost = { _ in false }
        let (source, _, _) = try await linked(at: "http://localhost:3000/", native: native)
        source.openOnPhone(tab)
        #expect(try page(source) is StreamedBrowserModel)
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
        ("http://localhost:3000", .macLoopback),
        ("http://app.localhost:8080", .macOnly),
        ("http://127.0.0.1:8000", .macLoopback),
        ("http://[::1]:8000", .macLoopback),
        ("file:///Users/me/index.html", .macOnly),
        ("view-source:https://example.com", .macOnly),
        ("http://mac-mini.tail137216.ts.net:3000", .privateNetwork),
        ("http://100.70.231.80:8080", .privateNetwork),
        ("http://192.168.1.20", .privateNetwork),
        ("http://studio.local:5000", .privateNetwork),
        ("http://devbox:8080", .privateNetwork),
        ("http://8.8.8.8", .web),
        ("http://127.0.0.2:8000", .macOnly),
        ("http://0.0.0.0:8000", .macOnly),
        ("mailto:someone@example.com", .web),
        ("tel:+15555550100", .web),
    ])
    func whereAnAddressPoints(_ address: String, _ reach: PhoneReach) {
        #expect(PhoneReach(URL(string: address)) == reach)
    }
}
#endif
