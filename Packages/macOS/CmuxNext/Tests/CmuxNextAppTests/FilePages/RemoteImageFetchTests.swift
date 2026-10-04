@testable import CmuxNextApp
import CmuxNextPages
import Foundation
import Synchronization
import Testing

/// The markdown page's remote images (`__image`, coordinator decision for S6): the host fetches a
/// URL the document chose, so it fetches https only, never a loopback, private, link-local,
/// unspecified or `.local` target, checks the address a name resolves to and connects to that
/// same address (no second DNS answer), checks every redirect (at most 3), and sends no cookies,
/// credentials or auth headers. A fake resolver and transport stand in for DNS and the network.
@Suite struct RemoteImageFetchTests {
    final class Resolver: RemoteImageResolving {
        let answers: [String: [IPAddress]]
        let asked = Mutex<[String]>([])
        init(_ answers: [String: [IPAddress]]) { self.answers = answers }
        func resolve(_ host: String) async throws -> [IPAddress] {
            asked.withLock { $0.append(host) }
            return answers[host] ?? []
        }
    }

    final class Transport: RemoteImageTransport {
        let replies: [String: RemoteImageResponse]
        let sent = Mutex<[RemoteImageRequest]>([])
        init(_ replies: [String: RemoteImageResponse]) { self.replies = replies }
        func send(_ request: RemoteImageRequest, maximumBytes: Int) async throws -> RemoteImageResponse {
            sent.withLock { $0.append(request) }
            guard let reply = replies[request.host + request.target] else { throw URLError(.cannotConnectToHost) }
            return reply
        }
    }

    static let png = Data([0x89, 0x50, 0x4E, 0x47])
    static let publicAddress = IPAddress(literal: "93.184.216.34")!

    static func image(_ data: Data = png, type: String = "image/png") -> RemoteImageResponse {
        RemoteImageResponse(status: 200, headers: ["content-type": type], body: data)
    }

    static func redirect(_ location: String) -> RemoteImageResponse {
        RemoteImageResponse(status: 302, headers: ["location": location], body: Data())
    }

    static func fetch(_ string: String, resolver: Resolver, transport: Transport) async -> PageResource? {
        guard let url = URL(string: string) else { return nil }
        return await GuardedRemoteImages(resolver: resolver, transport: transport).fetch(url)
    }

    @Test func aPublicHTTPSImageIsFetchedFromTheCheckedAddressWithNoCredentials() async throws {
        let resolver = Resolver(["cdn.example.com": [Self.publicAddress]])
        let transport = Transport(["cdn.example.com/a.png?x=1": Self.image()])
        let resource = await Self.fetch("https://cdn.example.com/a.png?x=1", resolver: resolver, transport: transport)
        #expect(resource == PageResource(data: Self.png, mimeType: "image/png"))
        let request = try #require(transport.sent.withLock { $0.first })
        #expect(request.address == Self.publicAddress, "connects to the address that was checked")
        #expect(request.port == 443)
        let names = Set(request.headers.keys.map { $0.lowercased() })
        #expect(names.isDisjoint(with: ["cookie", "authorization", "proxy-authorization"]))
        #expect(request.headers["Host"] == "cdn.example.com")
    }

    @Test func plainHTTPIsRefused() async {
        let transport = Transport([:])
        #expect(await Self.fetch("http://127.0.0.1/a.png", resolver: Resolver([:]), transport: transport) == nil)
        #expect(await Self.fetch("http://cdn.example.com/a.png", resolver: Resolver(["cdn.example.com": [Self.publicAddress]]),
                                 transport: transport) == nil)
        #expect(transport.sent.withLock { $0.isEmpty })
    }

    @Test func loopbackLinkLocalPrivateAndLocalTargetsAreRefused() async {
        let transport = Transport([:])
        for url in ["https://127.0.0.1/a.png", "https://169.254.169.254/latest/meta-data", "https://10.0.0.8/a.png",
                    "https://172.16.4.4/a.png", "https://192.168.1.1/a.png", "https://0.0.0.0/a.png", "https://[::1]/a.png",
                    "https://[::]/a.png", "https://[fe80::1]/a.png", "https://[fd12:3456::1]/a.png", "https://[fc00::1]/a.png",
                    "https://[::ffff:127.0.0.1]/a.png", "https://[::ffff:169.254.169.254]/a.png", "https://printer.local/a.png",
                    "https://localhost/a.png", "https://user:secret@cdn.example.com/a.png"] {
            #expect(await Self.fetch(url, resolver: Resolver(["cdn.example.com": [Self.publicAddress]]), transport: transport) == nil, "\(url)")
        }
        #expect(transport.sent.withLock { $0.isEmpty })
    }

    /// DNS that answers a private address (or any private address among several) is refused.
    @Test func aNameThatResolvesToAPrivateAddressIsRefused() async {
        let transport = Transport(["evil.example.com/a.png": Self.image()])
        let resolver = Resolver(["evil.example.com": [IPAddress(literal: "192.168.1.5")!]])
        #expect(await Self.fetch("https://evil.example.com/a.png", resolver: resolver, transport: transport) == nil)
        let mixed = Resolver(["evil.example.com": [Self.publicAddress, IPAddress(literal: "127.0.0.1")!]])
        #expect(await Self.fetch("https://evil.example.com/a.png", resolver: mixed, transport: transport) == nil)
        let mapped = Resolver(["evil.example.com": [IPAddress(literal: "::ffff:10.1.2.3")!]])
        #expect(await Self.fetch("https://evil.example.com/a.png", resolver: mapped, transport: transport) == nil)
        #expect(transport.sent.withLock { $0.isEmpty })
    }

    @Test func aRedirectIntoAPrivateAddressIsRefused() async {
        let resolver = Resolver(["cdn.example.com": [Self.publicAddress], "inside.example.com": [IPAddress(literal: "10.0.0.2")!]])
        let transport = Transport(["cdn.example.com/a.png": Self.redirect("https://inside.example.com/a.png"),
                                   "inside.example.com/a.png": Self.image()])
        #expect(await Self.fetch("https://cdn.example.com/a.png", resolver: resolver, transport: transport) == nil)
        #expect(transport.sent.withLock { $0.map(\.host) } == ["cdn.example.com"])
        let literal = Transport(["cdn.example.com/b.png": Self.redirect("https://127.0.0.1/b.png")])
        #expect(await Self.fetch("https://cdn.example.com/b.png", resolver: resolver, transport: literal) == nil)
        let insecure = Transport(["cdn.example.com/c.png": Self.redirect("http://cdn.example.com/c.png")])
        #expect(await Self.fetch("https://cdn.example.com/c.png", resolver: resolver, transport: insecure) == nil)
    }

    @Test func threeRedirectsAreFollowedAndAFourthIsRefused() async {
        let resolver = Resolver(["cdn.example.com": [Self.publicAddress]])
        let three = Transport(["cdn.example.com/0": Self.redirect("/1"), "cdn.example.com/1": Self.redirect("/2"),
                               "cdn.example.com/2": Self.redirect("https://cdn.example.com/3"), "cdn.example.com/3": Self.image()])
        #expect(await Self.fetch("https://cdn.example.com/0", resolver: resolver, transport: three)?.data == Self.png)
        let four = Transport(["cdn.example.com/0": Self.redirect("/1"), "cdn.example.com/1": Self.redirect("/2"),
                              "cdn.example.com/2": Self.redirect("/3"), "cdn.example.com/3": Self.redirect("/4"),
                              "cdn.example.com/4": Self.image()])
        #expect(await Self.fetch("https://cdn.example.com/0", resolver: resolver, transport: four) == nil)
        #expect(four.sent.withLock { $0.count } == 4)
        #expect(RemoteImagePolicy.maximumRedirects == 3)
    }

    @Test func onlyImagesUnderTheSizeLimitAreServed() async {
        let resolver = Resolver(["cdn.example.com": [Self.publicAddress]])
        let html = Transport(["cdn.example.com/a": Self.image(Data("<html>".utf8), type: "text/html")])
        #expect(await Self.fetch("https://cdn.example.com/a", resolver: resolver, transport: html) == nil)
        let big = Transport(["cdn.example.com/a": Self.image(Data(count: RemoteImagePolicy.maximumBytes + 1))])
        #expect(await Self.fetch("https://cdn.example.com/a", resolver: resolver, transport: big) == nil)
        let missing = Transport(["cdn.example.com/a": RemoteImageResponse(status: 404, headers: ["content-type": "image/png"], body: Self.png)])
        #expect(await Self.fetch("https://cdn.example.com/a", resolver: resolver, transport: missing) == nil)
    }

    @Test func addressesAreClassifiedByTheirBytes() throws {
        for address in ["8.8.8.8", "93.184.216.34", "2606:4700:4700::1111", "::ffff:8.8.8.8"] {
            #expect(try #require(IPAddress(literal: address)).isPublic, "\(address)")
        }
        for address in ["127.0.0.1", "10.1.1.1", "172.31.255.255", "192.168.0.1", "169.254.169.254", "0.0.0.0", "100.64.0.1",
                        "224.0.0.1", "255.255.255.255", "::1", "::", "fe80::1", "febf::1", "fc00::1", "fdff::1", "ff02::1",
                        "::ffff:127.0.0.1", "::ffff:192.168.1.1", "::ffff:169.254.169.254", "::ffff:0.0.0.0"] {
            #expect(try #require(IPAddress(literal: address)).isPublic == false, "\(address)")
        }
        #expect(IPAddress(literal: "cdn.example.com") == nil)
    }

    /// The HTTP the pinned transport speaks: a plain GET with the checked headers, and a parser
    /// for its answer (Content-Length or chunked, the limit enforced).
    @Test func theTransportsHTTPIsAPlainGETAndItsAnswerIsParsed() throws {
        let request = RemoteImagePolicy.request(for: try #require(URL(string: "https://cdn.example.com/a.png?x=1")), address: Self.publicAddress)
        let wire = String(decoding: PinnedTLSTransport.encode(request), as: UTF8.self)
        #expect(wire.hasPrefix("GET /a.png?x=1 HTTP/1.1\r\n"))
        #expect(wire.contains("\r\nHost: cdn.example.com\r\n"))
        #expect(wire.hasSuffix("\r\n\r\n"))
        #expect(!wire.lowercased().contains("cookie") && !wire.lowercased().contains("authorization"))
        let plain = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nContent-Length: 4\r\n\r\n".utf8) + Self.png
        let parsed = try PinnedTLSTransport.parse(plain, maximumBytes: 10)
        #expect(parsed.status == 200 && parsed.headers["content-type"] == "image/png" && parsed.body == Self.png)
        let chunked = Data("HTTP/1.1 200 OK\r\nContent-Type: image/png\r\nTransfer-Encoding: chunked\r\n\r\n2\r\n".utf8)
            + Self.png.prefix(2) + Data("\r\n2\r\n".utf8) + Self.png.suffix(2) + Data("\r\n0\r\n\r\n".utf8)
        let dechunked = try PinnedTLSTransport.parse(chunked, maximumBytes: 10)
        #expect(dechunked.status == 200 && dechunked.body == Self.png)
        #expect(PinnedTLSTransport.isComplete(plain) && PinnedTLSTransport.isComplete(chunked))
        #expect(!PinnedTLSTransport.isComplete(plain.dropLast()))
        #expect(throws: (any Error).self) { try PinnedTLSTransport.parse(plain, maximumBytes: 3) }
        let moved = Data("HTTP/1.1 301 Moved\r\nLocation: /b.png\r\nContent-Length: 0\r\n\r\n".utf8)
        let redirect = try PinnedTLSTransport.parse(moved, maximumBytes: 10)
        #expect(redirect.status == 301 && redirect.headers["location"] == "/b.png")
    }
}
