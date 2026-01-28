#if DEBUG
import Foundation

final class UpdateTestURLProtocol: URLProtocol {
    static let host = "cmuxterm.test"
    static let appcastPath = "/appcast.xml"
    static let updatePath = "/cmuxterm-test.zip"

    private static var isRegistered = false
    private static let registrationLock = NSLock()

    static func registerIfNeeded() {
        registrationLock.lock()
        defer { registrationLock.unlock() }
        guard !isRegistered else { return }
        URLProtocol.registerClass(UpdateTestURLProtocol.self)
        isRegistered = true
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        guard url.host == host else { return false }
        return true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let method = request.httpMethod?.uppercased() ?? "GET"
        let (statusCode, data, contentType) = payload(for: url)
        let headers = [
            "Content-Type": contentType,
            "Content-Length": "\(data.count)"
        ]

        let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)

        if method != "HEAD" {
            client?.urlProtocol(self, didLoad: data)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func payload(for url: URL) -> (Int, Data, String) {
        switch url.path {
        case Self.appcastPath:
            let data = Self.appcastData()
            return (200, data, "application/xml")
        case Self.updatePath:
            let data = Self.updateArchiveData()
            return (200, data, "application/octet-stream")
        default:
            let data = Data("Not Found".utf8)
            return (404, data, "text/plain")
        }
    }

    private static func appcastData() -> Data {
        let env = ProcessInfo.processInfo.environment
        let mode = env["CMUX_UI_TEST_FEED_MODE"] ?? "available"
        let version = env["CMUX_UI_TEST_UPDATE_VERSION"] ?? "9.9.9"
        let updateURL = "https://\(host)\(updatePath)"
        let updateLength = updateArchiveData().count

        let item: String
        if mode == "none" {
            item = ""
        } else {
            item = """
            <item>
              <title>cmuxterm \(version)</title>
              <sparkle:version>\(version)</sparkle:version>
              <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
              <enclosure url="\(updateURL)" length="\(updateLength)" type="application/octet-stream" />
            </item>
            """
        }

        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0"
          xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"
          xmlns:dc="http://purl.org/dc/elements/1.1/">
          <channel>
            <title>cmuxterm Test Updates</title>
            <link>https://\(host)</link>
            <description>Test updates feed</description>
            <language>en</language>
            \(item)
          </channel>
        </rss>
        """

        return Data(xml.utf8)
    }

    private static func updateArchiveData() -> Data {
        Data("cmuxterm test update".utf8)
    }
}
#endif
