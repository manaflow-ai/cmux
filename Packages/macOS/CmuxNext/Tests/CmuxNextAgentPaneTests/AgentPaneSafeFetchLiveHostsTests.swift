import Foundation
import Testing
@testable import CmuxNextAgentPane
import CmuxNextRemoteFetch
import CmuxNextWakeups

/// cx-bgvy, against real public hosts, only on request: CMUX_LIVE_NETWORK_TESTS=1, or a fleet
/// ci-step whose key contains `live-network` (CMUX_CI_STEP_KEY; the step env allowlist has no
/// variable for this). Never on a laptop: the pinned reply fetch loads what a browser loads. GitHub's image proxy, Imgur,
/// an S3 file behind CloudFront, a gzip-encoded SVG, a chunked reply, deflate and br bodies, and
/// a redirect each come back as the expected bytes.
@Suite(.serialized, .enabled(if: LiveNetworkRequest().isRequested))
nonisolated struct AgentPaneSafeFetchLiveHostsTests {

    nonisolated enum Expect: Sendable, CustomStringConvertible {
        case png, jpeg, svg
        case bytes(Int)
        case text(String)

        var description: String {
            switch self {
            case .png: "PNG"
            case .jpeg: "JPEG"
            case .svg: "SVG"
            case .bytes(let count): "\(count) bytes"
            case .text(let text): "text \(text)"
            }
        }

        func matches(_ data: Data) -> Bool {
            switch self {
            case .png: data.starts(with: [0x89, 0x50, 0x4e, 0x47])
            case .jpeg: data.starts(with: [0xff, 0xd8, 0xff])
            case .svg: String(decoding: data.prefix(4096), as: UTF8.self).contains("<svg")
            case .bytes(let count): data.count == count
            case .text(let text): String(decoding: data, as: UTF8.self).contains(text)
            }
        }
    }

    static let cases: [(String, Expect)] = [
        // GitHub camo (the image proxy of every README image).
        ("https://camo.githubusercontent.com/ab8813a90486b6a95520d3d2d7516eaeadac9fa75678b60f7d497140e4d5eba3/68747470733a2f2f73696e647265736f726875732e636f6d2f6173736574732f7468616e6b732f6465706f742d6c6f676f2d6c696768742e737667", .svg),
        ("https://i.imgur.com/CzXTtJV.jpg", .jpeg),
        // Imgur answers a removed image with a 302 to its placeholder PNG.
        ("https://i.imgur.com/3RbjU9t.png", .png),
        // S3 behind CloudFront.
        ("https://a0.awsstatic.com/libra-css/images/logos/aws_logo_smile_1200x630.png", .png),
        // Served with Content-Encoding: gzip.
        ("https://upload.wikimedia.org/wikipedia/commons/4/4f/SVG_Logo.svg", .svg),
        // Transfer-Encoding: chunked.
        ("https://httpbin.org/stream-bytes/4096?seed=7&chunk_size=512", .bytes(4096)),
        ("https://httpbin.org/gzip", .text("\"gzipped\": true")),
        ("https://httpbin.org/deflate", .text("\"deflated\": true")),
        ("https://httpbin.org/brotli", .text("\"brotli\": true")),
    ]

    @Test(arguments: cases)
    func aPublicHostLoads(_ url: String, _ expect: Expect) async throws {
        var fetch = AgentPaneSafeFetch()
        fetch.guarded.resolver = SystemRemoteResolver(runner: BackgroundWork(label: "test.live-hosts"))
        fetch.guarded.timeout = .seconds(30)
        let result = await fetch.fetch(try #require(URL(string: url)))
        switch result {
        case .success(let data):
            #expect(expect.matches(data), "\(url): \(data.count) bytes, not \(expect)")
        case .failure(let error):
            Issue.record("\(url): \(error)")
        }
    }
}

/// Whether this run asked for the live network suites.
nonisolated struct LiveNetworkRequest {
    var isRequested: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["CMUX_LIVE_NETWORK_TESTS"] == "1" || (environment["CMUX_CI_STEP_KEY"] ?? "").contains("live-network")
    }
}
