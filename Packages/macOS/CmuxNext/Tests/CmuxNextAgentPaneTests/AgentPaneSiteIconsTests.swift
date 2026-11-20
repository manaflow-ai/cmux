@testable import CmuxNextAgentPane
import CmuxNextRemoteFetch
import CmuxNextSettings
import CoreGraphics
import Foundation
import ImageIO
import CmuxNextWakeupsTestSupport
import Testing
import UniformTypeIdentifiers

/// A web link's site mark (`link.favicons`): the host answers each site's favicon as a PNG data URL,
/// asking the favicon service for the link's registrable domain only (never its subdomains, which
/// agent text could fill with data) through the guarded fetch, once per site, never for a local or
/// private name, never without the suffix list, never under `agentPane.images.remote = never`, at a
/// bounded rate, and only an image answer counts. Every network hop is a stub; nothing leaves the test.
@MainActor
struct AgentPaneSiteIconsTests {
    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }

    private nonisolated struct PublicResolver: RemoteAddressResolving {
        func resolve(_ host: String) async throws -> [RemoteAddress] { [.v4([151, 101, 0, 223])] }
    }

    /// Answers every request with `body` and `type`; records each host and path it was sent.
    private nonisolated final class Site: RemoteFetchTransport, @unchecked Sendable { // crash-allow: test support; the lock holds the state
        private let lock = NSLock()
        private var seen: [String] = []
        private let body: Data
        private let type: String

        init(body: Data, type: String) {
            self.body = body
            self.type = type
        }

        var requests: [String] { lock.withLock { seen } }

        func send(_ request: RemoteFetchRequest, maximumBytes: Int) async throws -> RemoteFetchResponse {
            lock.withLock { seen.append(request.host + request.target) }
            return RemoteFetchResponse(status: 200, headers: ["content-type": type], body: body)
        }
    }

    /// A 48 px PNG, as a site's favicon.
    private static func png() throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 48, height: 48))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// A small stand-in for the app's Public Suffix List: the longest listed suffix plus one label.
    private nonisolated static func registrable(_ host: String) -> String? {
        let suffixes = ["com", "dev", "org", "io", "uk", "co.uk", "github.io", "net", "ts.net"]
        let labels = host.split(separator: ".").map(String.init)
        for start in labels.indices where suffixes.contains(labels[start...].joined(separator: ".")) {
            return start == 0 ? nil : labels[(start - 1)...].joined(separator: ".")
        }
        return nil
    }

    private static let domains = AgentPaneSiteDomains { { registrable($0) } }

    private static func pane(_ site: Site, remoteImages: AgentPaneReplySetting.RemoteImages = .click,
                             domains: AgentPaneSiteDomains = domains, clock: ManualClock = ManualClock()) -> AgentPaneModel {
        let model = AgentPaneModel(host: NoHost())
        model.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .open, remoteImages: remoteImages) }
        model.replyLinks.siteIcons = AgentPaneSiteIcons(domains: domains, clock: clock)
        model.replyLinks.siteIcons.guarded.resolver = PublicResolver()
        model.replyLinks.siteIcons.guarded.transport = site
        return model
    }

    private static func icons(_ model: AgentPaneModel, _ hosts: [String]) async -> [String: String] {
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "link.favicons", "params": ["hosts": hosts]]))
        return ((reply["value"] as? [String: Any])?["icons"] as? [String: String]) ?? [:]
    }

    @Test func theRequestTakesOnlyLowercaseHostNamesAndIsPassive() {
        let request = AgentPaneReplyRequest(method: "link.favicons", params: ["hosts": ["react.dev", "docs.python.org"]])
        #expect(request == .siteIcons(["react.dev", "docs.python.org"]))
        #expect(request?.isPassive == true)
        #expect(AgentPaneReplyRequest.methods.contains("link.favicons"))
        #expect(AgentPaneReplyRequest(method: "link.favicons", params: ["hosts": []]) == nil)
        #expect(AgentPaneReplyRequest(method: "link.favicons", params: ["hosts": ["React.dev"]]) == nil)
        #expect(AgentPaneReplyRequest(method: "link.favicons", params: ["hosts": ["a.dev/x"]]) == nil)
        #expect(AgentPaneReplyRequest(method: "link.favicons", params: ["hosts": ["a.dev"], "urls": []]) == nil)
        let tooMany = (0...AgentPaneReplyRequest.maximumSiteIcons).map { "site\($0).dev" }
        #expect(AgentPaneReplyRequest(method: "link.favicons", params: ["hosts": tooMany]) == nil)
    }

    @Test func onlyAPublicHostNameIsAsked() {
        #expect(AgentPaneSiteIcons.publicHost(of: "docs.python.org") == "docs.python.org")
        #expect(AgentPaneSiteIcons.publicHost(of: "React.dev.") == "react.dev")
        #expect(AgentPaneSiteIcons.publicHost(of: "news.bbc.co.uk") == "news.bbc.co.uk")
        for name in ["localhost", "app.localhost", "printer.local", "db.internal", "mymac", "10.0.0.1", "8.8.8.8",
                     "docs.example.test", "router.lan", "a..b", "-a.dev", "",
                     "jira.corp.acme.com", "wiki.intranet.acme.com", "api.internal.acme.io", "nas.home", "box.private", "x.alt",
                     "box.tail1234.ts.net", "ts.net", "login.tailscale.net", "1.0.0.10.in-addr.arpa", "nas.localdomain"] {
            #expect(AgentPaneSiteIcons.publicHost(of: name) == nil, "\(name)")
        }
    }

    @Test func theFetchReachesOnlyTheServiceAndItsImageServers() throws {
        #expect(AgentPaneSiteIcons().guarded.hosts == AgentPaneSiteIcons.serviceHosts)
        let redirect = try #require(URL(string: "https://t2.gstatic.com/faviconV2?url=http://react.dev&size=32"))
        let elsewhere = try #require(URL(string: "https://icons.example.org/react.png"))
        #expect(GuardedRemoteFetch.isListed(redirect, in: AgentPaneSiteIcons.serviceHosts))
        #expect(!GuardedRemoteFetch.isListed(elsewhere, in: AgentPaneSiteIcons.serviceHosts))
    }

    @Test func theServiceIsAskedForTheHostNameOnly() throws {
        let url = try #require(AgentPaneSiteIcons.serviceURL("doc.rust-lang.org"))
        #expect(url.absoluteString == "https://www.google.com/s2/favicons?domain=doc.rust-lang.org&sz=32")
    }

    @Test func aSitesIconIsFetchedOncePerSiteAsAPNG() async throws {
        let site = Site(body: try Self.png(), type: "image/png")
        let model = Self.pane(site)
        let first = await Self.icons(model, ["docs.python.org", "localhost"])
        #expect(first.keys.sorted() == ["docs.python.org"])
        #expect(first.values.allSatisfy { $0.hasPrefix("data:image/png;base64,") })
        #expect(site.requests == ["www.google.com/s2/favicons?domain=python.org&sz=32"])
        // Kept: a later request for the same host fetches nothing.
        let again = await Self.icons(model, ["docs.python.org"])
        #expect(again["docs.python.org"] != nil)
        #expect(site.requests.count == 1)
    }

    @Test func aPageIsNoIconAndIsNotAskedAgain() async throws {
        let site = Site(body: Data("<html>Not found</html>".utf8), type: "text/html; charset=utf-8")
        let model = Self.pane(site)
        #expect(await Self.icons(model, ["example.org"]).isEmpty)
        #expect(await Self.icons(model, ["example.org"]).isEmpty)
        #expect(site.requests.count == 1)
    }

    @Test func bytesThatAreNoImageAreNoIcon() async throws {
        let site = Site(body: Data("GIF89a not really".utf8), type: "image/gif")
        #expect(await Self.icons(Self.pane(site), ["react.dev"]).isEmpty)
    }

    @Test func underNeverNoSiteIsAsked() async throws {
        let site = Site(body: try Self.png(), type: "image/png")
        let model = Self.pane(site, remoteImages: .never)
        #expect(await Self.icons(model, ["react.dev", "docs.python.org"]).isEmpty)
        #expect(site.requests.isEmpty)
    }

    @Test func anIconCmuxsTabsHaveWinsWithoutAFetch() async throws {
        let site = Site(body: try Self.png(), type: "image/png")
        let model = Self.pane(site)
        let tabIcon = try Self.png()
        model.replyLinks.sites = { urls in
            Dictionary(uniqueKeysWithValues: urls.filter { $0.host() == "react.dev" }.map { ($0, AgentPaneReplySite(iconPNG: tabIcon)) })
        }
        let icons = await Self.icons(model, ["react.dev"])
        #expect(icons["react.dev"] == "data:image/png;base64," + tabIcon.base64EncodedString())
        #expect(site.requests.isEmpty)
    }

    /// A 48 px PNG: a centred square of `gray` on a clear ground.
    private static func mark(gray: CGFloat) throws -> Data {
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: 48, height: 48, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.clear(CGRect(x: 0, y: 0, width: 48, height: 48))
        context.setFillColor(CGColor(srgbRed: gray, green: gray, blue: gray, alpha: 1))
        context.fill(CGRect(x: 12, y: 12, width: 24, height: 24))
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    /// The alpha of the drawn icon's corner pixel: 0 when clear, high on a plate.
    private static func cornerAlpha(_ dataURL: String) throws -> UInt8 {
        let base64 = try #require(dataURL.split(separator: ",").last)
        let data = try #require(Data(base64Encoded: String(base64)))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let pixels = try #require(context.data).bindMemory(to: UInt8.self, capacity: context.bytesPerRow * context.height)
        // A pixel a little in from the corner, inside the plate's rounding.
        let at = (image.height / 2) * context.bytesPerRow + 2 * 4
        return pixels[at + 3]
    }

    @Test func aDarkMarkOnAClearGroundGetsALightPlate() throws {
        let dark = try #require(AgentPaneSiteIconImage.png(try Self.mark(gray: 0.05)))
        let light = try #require(AgentPaneSiteIconImage.png(try Self.mark(gray: 0.9)))
        let solid = try #require(AgentPaneSiteIconImage.png(try Self.png()))
        #expect(try Self.cornerAlpha(dark) > 200)
        #expect(try Self.cornerAlpha(light) == 0)
        // A full-bleed icon has no clear ground and stays as it is.
        #expect(solid == AgentPaneSiteIconImage.png(try Self.png()))
    }

    @Test func theTypeCheckRefusesPagesAndSVG() {
        #expect(AgentPaneSiteIcons.isImageType(nil))
        #expect(AgentPaneSiteIcons.isImageType("image/x-icon"))
        #expect(AgentPaneSiteIcons.isImageType("image/vnd.microsoft.icon"))
        #expect(AgentPaneSiteIcons.isImageType("application/octet-stream"))
        #expect(!AgentPaneSiteIcons.isImageType("text/html; charset=utf-8"))
        #expect(!AgentPaneSiteIcons.isImageType("image/svg+xml"))
        #expect(!AgentPaneSiteIcons.isImageType("application/json"))
    }

    @Test func onlyTheRegistrableDomainLeavesTheMac() async throws {
        let site = Site(body: try Self.png(), type: "image/png")
        let model = Self.pane(site)
        let hosts = ["c2vjcmv0.evil.com", "dg9rzw4.evil.com", "react.dev", "someone.github.io"]
        let icons = await Self.icons(model, hosts)
        #expect(icons.keys.sorted() == hosts.sorted())
        #expect(Set(site.requests) == [
            "www.google.com/s2/favicons?domain=evil.com&sz=32", "www.google.com/s2/favicons?domain=react.dev&sz=32",
            "www.google.com/s2/favicons?domain=someone.github.io&sz=32",
        ])
        #expect(!site.requests.contains { $0.contains("c2vjcmv0") || $0.contains("dg9rzw4") })
    }

    @Test func withoutTheSuffixListNothingIsFetched() async throws {
        let site = Site(body: try Self.png(), type: "image/png")
        #expect(await Self.icons(Self.pane(site, domains: AgentPaneSiteDomains { nil }), ["react.dev"]).isEmpty)
        #expect(site.requests.isEmpty)
        // A pane that never got the app's list (tests, previews) fetches nothing either.
        let bare = AgentPaneModel(host: NoHost())
        bare.replyLinks.settings = { AgentPaneReplySetting(outsideRoots: .open, remoteImages: .always) }
        bare.replyLinks.siteIcons.guarded.resolver = PublicResolver()
        bare.replyLinks.siteIcons.guarded.transport = site
        #expect(await Self.icons(bare, ["react.dev"]).isEmpty)
        #expect(site.requests.isEmpty)
    }

    private static func reply(_ model: AgentPaneModel, _ hosts: [String]) async -> (icons: [String: String], later: [String], retry: Int?) {
        let reply = await model.respond(to: AgentPaneRequest(body: ["method": "link.favicons", "params": ["hosts": hosts]]))
        let value = reply["value"] as? [String: Any]
        return ((value?["icons"] as? [String: String]) ?? [:], (value?["later"] as? [String]) ?? [], value?["retryAfterMs"] as? Int)
    }

    @Test func pastTheBurstASiteIsAnsweredLaterAndFetchedInTheNextWindow() async throws {
        let site = Site(body: try Self.png(), type: "image/png")
        let clock = ManualClock()
        let model = Self.pane(site, clock: clock)
        model.replyLinks.siteIcons.burst = 2
        // The reply does not wait for the window: the third site comes back as `later`.
        let first = await Self.reply(model, ["a.dev", "b.dev", "c.dev"])
        #expect(first.icons.keys.sorted() == ["a.dev", "b.dev"])
        #expect(first.later == ["c.dev"])
        #expect(first.retry == 30000)
        #expect(site.requests.count == 2)
        // Not kept as having no icon: once the window ends, the same ask fetches it.
        try await clock.waitForSleeper()
        clock.advance(by: model.replyLinks.siteIcons.refillEvery)
        var answered: [String: String] = [:]
        for _ in 0..<1000 where answered.isEmpty {
            answered = await Self.reply(model, ["c.dev"]).icons
            await Task.yield()
        }
        #expect(answered.keys.sorted() == ["c.dev"])
        #expect(site.requests.count == 3)
    }
}
