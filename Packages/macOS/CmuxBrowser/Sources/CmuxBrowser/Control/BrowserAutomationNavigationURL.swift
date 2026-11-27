import Foundation

/// A deterministic URL value for matching WebKit same-document navigation reports.
struct BrowserAutomationNavigationURL: Equatable {
    private static let uppercaseHexadecimal = Array("0123456789ABCDEF".utf8)

    private let scheme: String?
    private let user: String?
    private let password: String?
    private let host: String?
    private let port: Int?
    private let path: String
    private let query: String?
    private let fragment: String?

    init?(_ url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let normalizedScheme = components.scheme?.lowercased()
        scheme = normalizedScheme
        user = components.percentEncodedUser.map(Self.normalizePercentEncoding)
        password = components.percentEncodedPassword.map(Self.normalizePercentEncoding)
        host = components.host?.lowercased()
        switch (normalizedScheme, components.port) {
        case ("http", 80), ("https", 443):
            port = nil
        default:
            port = components.port
        }

        let normalizedPath = Self.normalizePercentEncoding(components.percentEncodedPath)
        if (normalizedScheme == "http" || normalizedScheme == "https"),
           components.host != nil,
           normalizedPath.isEmpty {
            path = "/"
        } else {
            path = normalizedPath
        }
        query = components.percentEncodedQuery.map(Self.normalizePercentEncoding)
        fragment = components.percentEncodedFragment.map(Self.normalizePercentEncoding)
    }

    private static func normalizePercentEncoding(_ value: String) -> String {
        let bytes = Array(value.utf8)
        var normalized: [UInt8] = []
        normalized.reserveCapacity(bytes.count)
        var index = 0

        while index < bytes.count {
            if bytes[index] == 0x25,
               index + 2 < bytes.count,
               let high = hexadecimalValue(bytes[index + 1]),
               let low = hexadecimalValue(bytes[index + 2]) {
                let decoded = high << 4 | low
                if isUnreserved(decoded) {
                    normalized.append(decoded)
                } else {
                    normalized.append(0x25)
                    normalized.append(uppercaseHexadecimal[Int(decoded >> 4)])
                    normalized.append(uppercaseHexadecimal[Int(decoded & 0x0F)])
                }
                index += 3
                continue
            }

            normalized.append(bytes[index])
            index += 1
        }

        return String(decoding: normalized, as: UTF8.self)
    }

    private static func hexadecimalValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static func isUnreserved(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E: true
        default: false
        }
    }
}
