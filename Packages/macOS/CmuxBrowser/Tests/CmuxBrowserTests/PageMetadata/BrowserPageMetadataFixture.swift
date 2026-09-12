import Foundation
@testable import CmuxBrowser

struct BrowserPageMetadataFixture {
    func response(
        status: Int = 200,
        headers: [String: String] = ["Content-Type": "text/html; charset=utf-8"],
        body: String = ""
    ) -> BrowserPageMetadataHTTPResponse {
        var lines = ["HTTP/1.1 \(status) Test"]
        lines.append(contentsOf: headers.map { "\($0.key): \($0.value)" })
        let bodyData = Data(body.utf8)
        lines.append("Content-Length: \(bodyData.count)")
        lines.append("")
        lines.append("")
        var wireData = Data(lines.joined(separator: "\r\n").utf8)
        wireData.append(bodyData)
        return BrowserPageMetadataHTTPResponse(
            wireData: wireData,
            maximumBodyBytes: 65_536
        )!
    }
}
