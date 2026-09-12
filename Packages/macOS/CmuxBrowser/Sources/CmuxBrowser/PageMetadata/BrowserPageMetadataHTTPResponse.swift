import Foundation

/// A bounded HTTP/1 response used by page-metadata fetches.
struct BrowserPageMetadataHTTPResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    var redirectLocation: String? {
        (300..<400).contains(statusCode) ? headers["location"] : nil
    }

    init?(wireData: Data, maximumBodyBytes: Int) {
        guard let delimiter = wireData.range(of: Data([13, 10, 13, 10])),
              delimiter.lowerBound <= 64 * 1024,
              let rawHeaders = String(data: wireData[..<delimiter.lowerBound], encoding: .isoLatin1) else {
            return nil
        }
        let lines = rawHeaders.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return nil }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              statusParts[0].hasPrefix("HTTP/1."),
              let statusCode = Int(statusParts[1]) else {
            return nil
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty,
                  name.utf8.allSatisfy({ $0 >= 0x21 && $0 != 0x7F }),
                  value.utf8.allSatisfy({ $0 == 0x09 || $0 >= 0x20 && $0 != 0x7F }) else {
                return nil
            }
            headers[name] = value
        }

        let encodedBody = Data(wireData[delimiter.upperBound...])
        let body: Data
        if headers["transfer-encoding"]?
            .split(separator: ",")
            .contains(where: { $0.trimmingCharacters(in: .whitespaces).lowercased() == "chunked" }) == true {
            guard let decoded = BrowserHTTPChunkedBodyDecoder(maximumBytes: maximumBodyBytes)
                .decode(encodedBody) else {
                return nil
            }
            body = decoded
        } else if let rawLength = headers["content-length"] {
            guard let length = Int(rawLength),
                  length >= 0,
                  length <= maximumBodyBytes,
                  encodedBody.count >= length else {
                return nil
            }
            body = Data(encodedBody.prefix(length))
        } else {
            guard encodedBody.count <= maximumBodyBytes else { return nil }
            body = encodedBody
        }

        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}
