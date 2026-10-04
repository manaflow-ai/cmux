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

    /// The request the pinned transport sends: HTTP/1.0, `Connection: close`, `Accept-Encoding:
    /// identity`, the checked headers only.
    @Test func theRequestIsAPlainHTTP10GET() throws {
        let request = RemoteImagePolicy.request(for: try #require(URL(string: "https://cdn.example.com/a.png?x=1")), address: Self.publicAddress)
        let wire = String(decoding: PinnedTLSTransport.encode(request), as: UTF8.self)
        #expect(wire.hasPrefix("GET /a.png?x=1 HTTP/1.0\r\n"))
        #expect(wire.contains("\r\nHost: cdn.example.com\r\n"))
        #expect(wire.contains("\r\nConnection: close\r\n") && wire.contains("\r\nAccept-Encoding: identity\r\n"))
        #expect(wire.hasSuffix("\r\n\r\n"))
        #expect(!wire.lowercased().contains("cookie") && !wire.lowercased().contains("authorization"))
    }

    // MARK: The reply reader (CFHTTPMessage for the status line and headers)

    static func head(_ lines: [String]) -> Data { Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) }

    /// Feeds `chunks` and ends the stream; the reply or the error.
    static func read(_ chunks: [Data], cap: Int = 10) -> Result<RemoteImageResponse, any Error> {
        var reader = HTTPReplyReader(maximumBody: cap)
        do {
            for chunk in chunks {
                if try reader.append(chunk) { return .success(try reader.finish()) }
            }
            return .success(try reader.finish())
        } catch {
            return .failure(error)
        }
    }

    static func refused(_ chunks: [Data], cap: Int = 10) -> Bool {
        if case .failure = read(chunks, cap: cap) { return true }
        return false
    }

    @Test func aReplyWithContentLengthEndsThereAndOneWithoutAtTheClose() throws {
        let sized = try Self.read([Self.head(["HTTP/1.0 200 OK", "Content-Type: image/png", "Content-Length: 4"]) + Self.png + Data("extra".utf8)]).get()
        #expect(sized.status == 200 && sized.headers["content-type"] == "image/png" && sized.body == Self.png)
        let open = try Self.read([Self.head(["HTTP/1.0 200 OK", "Content-Type: image/png"]), Self.png.prefix(2), Self.png.suffix(2)]).get()
        #expect(open.body == Self.png)
        let moved = try Self.read([Self.head(["HTTP/1.0 302 Found", "Location: /b.png", "Content-Length: 0"])]).get()
        #expect(moved.status == 302 && moved.headers["location"] == "/b.png")
    }

    @Test func transferAndContentEncodingsAreRefused() {
        #expect(Self.refused([Self.head(["HTTP/1.1 200 OK", "Transfer-Encoding: chunked"]) + Data("4\r\nabcd\r\n0\r\n\r\n".utf8)]))
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", "Content-Encoding: gzip", "Content-Length: 4"]) + Self.png]))
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", "Content-Encoding: identity", "Content-Length: 4"]) + Self.png]))
    }

    @Test func repeatedConflictingOrMalformedContentLengthsAreRefused() {
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", "Content-Length: 4", "Content-Length: 4"]) + Self.png]))
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", "Content-Length: 4", "content-length: 5"]) + Self.png]))
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", "Content-Length: 4, 5"]) + Self.png]))
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", "Content-Length: -1"]) + Self.png]))
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", "Content-Length: 0x4"]) + Self.png]))
    }

    @Test func aHeaderBlockOver16KBIsRefused() {
        let big = "X-Filler: " + String(repeating: "a", count: 16 * 1024)
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", big, "Content-Length: 4"]) + Self.png]))
        // Never complete: refused once 16 KB arrive without the end of the headers.
        #expect(Self.refused([Data("HTTP/1.0 200 OK\r\n".utf8), Data(repeating: 0x61, count: 17 * 1024)]))
    }

    @Test func statusesOtherThan200AndRedirectsAreRefused() {
        for status in ["404 Not Found", "500 Internal Server Error", "206 Partial Content", "304 Not Modified", "100 Continue"] {
            #expect(Self.refused([Self.head(["HTTP/1.0 \(status)", "Content-Length: 4"]) + Self.png]), "\(status)")
        }
        #expect(Self.refused([Data("not http at all\r\n\r\n".utf8)]))
    }

    @Test func theBodyCapHoldsWhileReading() {
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", "Content-Length: 11"])], cap: 10), "a declared body over the cap")
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK"]), Data(count: 6), Data(count: 6)], cap: 10), "an open body over the cap")
        #expect(Self.refused([Self.head(["HTTP/1.0 200 OK", "Content-Length: 4"]) + Self.png.prefix(2)]), "short at the close")
        #expect(Self.refused([]), "nothing at all")
    }

    /// Random and mutated replies in random pieces: the reader never crashes, always ends, and
    /// never holds more body than the cap. Fixed seed, so a failure reproduces.
    @Test func fuzzedRepliesNeverCrashHangOrPassTheCap() {
        struct SplitMix64 {
            var state: UInt64
            mutating func next() -> UInt64 {
                state &+= 0x9E37_79B9_7F4A_7C15
                var z = state
                z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
                z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
                return z ^ (z >> 31)
            }
            mutating func below(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
        }
        var random = SplitMix64(state: 0x5EED_F11E)
        let seeds: [Data] = [
            Self.head(["HTTP/1.0 200 OK", "Content-Type: image/png", "Content-Length: 4"]) + Self.png,
            Self.head(["HTTP/1.0 302 Found", "Location: /x"]),
            Self.head(["HTTP/1.1 200 OK", "Transfer-Encoding: chunked"]) + Data("4\r\nabcd\r\n0\r\n\r\n".utf8),
            Self.head(["HTTP/1.0 200 OK"]) + Data(count: 64),
        ]
        let cap = 32
        for _ in 0..<2000 {
            var reply = seeds[random.below(seeds.count)]
            for _ in 0..<random.below(8) {
                switch random.below(4) {
                case 0 where !reply.isEmpty: reply[reply.startIndex + random.below(reply.count)] = UInt8(truncatingIfNeeded: random.next())
                case 1: reply.insert(UInt8(truncatingIfNeeded: random.next()), at: reply.startIndex + random.below(reply.count + 1))
                case 2 where !reply.isEmpty: reply.remove(at: reply.startIndex + random.below(reply.count))
                default: reply.append(contentsOf: (0..<random.below(40)).map { _ in UInt8(truncatingIfNeeded: random.next()) })
                }
            }
            var chunks: [Data] = []
            var rest = reply[...]
            while !rest.isEmpty {
                let size = 1 + random.below(rest.count)
                chunks.append(Data(rest.prefix(size)))
                rest = rest.dropFirst(size)
            }
            if case .success(let response) = Self.read(chunks, cap: cap) {
                #expect(response.body.count <= cap)
            }
        }
    }
}
