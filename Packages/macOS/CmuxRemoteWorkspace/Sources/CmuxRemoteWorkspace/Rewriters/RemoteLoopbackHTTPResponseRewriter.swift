public import Foundation
import CmuxCore

/// Rewrites proxied HTTP response header bytes so localhost-family hosts in
/// `Location` / `Content-Location` / `Origin` / `Referer` /
/// `Access-Control-Allow-Origin` / `Set-Cookie` headers are mapped back to
/// the loopback alias domain the browser is actually visiting.
///
/// Static members only: pure byte-in/byte-out transforms with no state to
/// hold (one-line justification per the no-namespace-enum convention).
public struct RemoteLoopbackHTTPResponseRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])

    /// Rewrites `data` when it begins with a complete HTTP response header
    /// block; returns the input unchanged otherwise.
    public static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        guard let headerRange = data.range(of: headerDelimiter) else { return data }
        let headerData = Data(data[..<headerRange.upperBound])
        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard let statusLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard lines[statusLineIndex].uppercased().hasPrefix("HTTP/") else { return data }

        for index in (statusLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + data[headerRange.upperBound...]
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "location", "content-location", "origin", "referer", "access-control-allow-origin":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        case "set-cookie":
            guard let rewrittenCookie = rewriteCookieValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenCookie)"
        default:
            return line
        }
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              let rewrittenHost = RemoteLoopbackProxyAlias.localhostFamilyAliasHost(forLoopbackHost: host, aliasHost: aliasHost) else {
            return nil
        }
        components?.host = rewrittenHost
        return components?.string
    }

    private static func rewriteCookieValue(_ value: String, aliasHost: String) -> String? {
        let parts = value.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty else { return nil }

        var didRewrite = false
        let rewrittenParts = parts.map { part -> String in
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("domain=") else { return part }
            let domainValue = String(trimmed.dropFirst("domain=".count))
            let hasLeadingDot = domainValue.hasPrefix(".")
            let hostValue = hasLeadingDot ? String(domainValue.dropFirst()) : domainValue
            guard let rewrittenHost = RemoteLoopbackProxyAlias.localhostFamilyAliasHost(
                forLoopbackHost: hostValue,
                aliasHost: aliasHost
            ) else {
                return part
            }
            didRewrite = true
            let leadingWhitespace = part.prefix { $0.isWhitespace }
            let rewrittenDomain = hasLeadingDot ? ".\(rewrittenHost)" : rewrittenHost
            return "\(leadingWhitespace)Domain=\(rewrittenDomain)"
        }

        return didRewrite ? rewrittenParts.joined(separator: ";") : nil
    }
}
