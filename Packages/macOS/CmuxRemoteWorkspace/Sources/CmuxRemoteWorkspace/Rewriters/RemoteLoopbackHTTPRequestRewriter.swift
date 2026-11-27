public import Foundation
import CmuxCore

/// Rewrites proxied HTTP request bytes whose request line / `Host` / `Origin`
/// / `Referer` headers carry the loopback alias domain back to the
/// localhost-family hosts the remote daemon can actually dial.
///
/// Static members only: these are pure byte-in/byte-out transforms with no
/// state to hold (one-line justification per the no-namespace-enum
/// convention); the stateful incremental variant is
/// ``RemoteLoopbackHTTPRequestStreamRewriter``.
public struct RemoteLoopbackHTTPRequestRewriter {
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])
    private static let requestLineMethods = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE", "PRI"]

    /// Rewrites `data` when it begins with a complete HTTP request header
    /// block; returns the input unchanged otherwise.
    public static func rewriteIfNeeded(data: Data, aliasHost: String) -> Data {
        rewriteIfNeeded(data: data, aliasHost: aliasHost, allowIncompleteHeadersAtEOF: false)
    }

    /// Like ``rewriteIfNeeded(data:aliasHost:)``, but when
    /// `allowIncompleteHeadersAtEOF` is true the whole payload is treated as
    /// headers even without the terminating CRLFCRLF (used when the stream
    /// hit EOF mid-header).
    public static func rewriteIfNeeded(data: Data, aliasHost: String, allowIncompleteHeadersAtEOF: Bool) -> Data {
        let headerData: Data
        let remainder: Data

        if let headerRange = data.range(of: headerDelimiter) {
            headerData = Data(data[..<headerRange.upperBound])
            remainder = Data(data[headerRange.upperBound...])
        } else if allowIncompleteHeadersAtEOF {
            headerData = data
            remainder = Data()
        } else {
            return data
        }

        guard let headerText = String(data: headerData, encoding: .utf8) else { return data }

        var lines = headerText.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return data }
        guard let requestLineIndex = lines.firstIndex(where: { !$0.isEmpty }) else { return data }
        guard requestLineLooksHTTP(lines[requestLineIndex]) else { return data }

        let rewrittenRequestLine = rewriteRequestLine(lines[requestLineIndex], aliasHost: aliasHost)
        if rewrittenRequestLine != lines[requestLineIndex] {
            lines[requestLineIndex] = rewrittenRequestLine
        }

        for index in (requestLineIndex + 1)..<lines.count where !lines[index].isEmpty {
            lines[index] = rewriteHeaderLine(lines[index], aliasHost: aliasHost)
        }

        let rewrittenHeaderText = lines.joined(separator: "\r\n")
        guard rewrittenHeaderText != headerText else { return data }
        return Data(rewrittenHeaderText.utf8) + remainder
    }

    private static func requestLineLooksHTTP(_ requestLine: String) -> Bool {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let method = trimmed.split(separator: " ", maxSplits: 1).first.map(String.init)?.uppercased() ?? ""
        return requestLineMethods.contains(method)
    }

    private static func rewriteRequestLine(_ requestLine: String, aliasHost: String) -> String {
        let trimmed = requestLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return requestLine }

        var components = URLComponents(string: String(parts[1]))
        guard let host = components?.host,
              let loopbackHost = RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: host, aliasHost: aliasHost) else {
            return requestLine
        }
        components?.host = loopbackHost
        guard let rewrittenURL = components?.string else { return requestLine }

        var rewritten = parts
        rewritten[1] = Substring(rewrittenURL)
        let leadingTrivia = requestLine.prefix { $0.isWhitespace || $0.isNewline }
        let trailingTrivia = String(requestLine.reversed().prefix { $0.isWhitespace || $0.isNewline }.reversed())
        return String(leadingTrivia) + rewritten.joined(separator: " ") + trailingTrivia
    }

    private static func rewriteHeaderLine(_ line: String, aliasHost: String) -> String {
        guard let colonIndex = line.firstIndex(of: ":") else { return line }
        let name = line[..<colonIndex].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let valueStart = line.index(after: colonIndex)
        let rawValue = line[valueStart...].trimmingCharacters(in: .whitespacesAndNewlines)

        switch name {
        case "host":
            guard let rewrittenHost = rewriteHostValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenHost)"
        case "origin", "referer":
            guard let rewrittenURL = rewriteURLValue(rawValue, aliasHost: aliasHost) else { return line }
            return "\(line[..<valueStart]) \(rewrittenURL)"
        default:
            return line
        }
    }

    private static func rewriteHostValue(_ value: String, aliasHost: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("["),
           let closing = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closing])
            guard let loopbackHost = RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: host, aliasHost: aliasHost) else {
                return nil
            }
            let remainder = String(trimmed[closing...].dropFirst())
            return loopbackHost + remainder
        }

        if let colonIndex = trimmed.lastIndex(of: ":"), !trimmed[..<colonIndex].contains(":") {
            let host = String(trimmed[..<colonIndex])
            guard let loopbackHost = RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: host, aliasHost: aliasHost) else {
                return nil
            }
            return loopbackHost + trimmed[colonIndex...]
        }

        guard let loopbackHost = RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: trimmed, aliasHost: aliasHost) else {
            return nil
        }
        return loopbackHost
    }

    private static func rewriteURLValue(_ value: String, aliasHost: String) -> String? {
        var components = URLComponents(string: value)
        guard let host = components?.host,
              let loopbackHost = RemoteLoopbackProxyAlias.localhostFamilyHost(forAliasHost: host, aliasHost: aliasHost) else {
            return nil
        }
        components?.host = loopbackHost
        return components?.string
    }
}
