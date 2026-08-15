import CmuxTerminalCore
import Darwin
import Foundation

@MainActor
final class LinkTitleFetcher {
    static let shared = LinkTitleFetcher()
    private static let maximumBodyBytes = 65_536

    private struct FetchKey: Hashable {
        let workspaceId: UUID
        let url: String
    }

    private var inFlight: Set<FetchKey> = []
    private var failed: Set<FetchKey> = []

    private init() {}

    func fetchTitleIfNeeded(for entry: WorkspaceCapturedLink, workspace: Workspace) async {
        let key = FetchKey(workspaceId: workspace.id, url: entry.url)
        guard LinksCaptureSettings.snapshot().fetchTitles,
              entry.fetchedTitle == nil,
              Self.mayFetchTitle(url: entry.url, hostKey: entry.hostKey),
              !inFlight.contains(key),
              !failed.contains(key) else {
            return
        }
        inFlight.insert(key)
        defer { inFlight.remove(key) }

        guard let url = URL(string: entry.url) else {
            failed.insert(key)
            return
        }
        // URLSession resolves again at connect time, so a fast-rebinding host
        // can still race this preflight; accepted for opt-in local title fetches.
        guard let host = url.host(),
              await Self.hostResolvesOnlyToPublicAddresses(host) else {
            failed.insert(key)
            return
        }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5
            request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
            let redirectDelegate = LinkTitleRedirectDelegate()
            let (bytes, response) = try await URLSession.shared.bytes(
                for: request,
                delegate: redirectDelegate
            )
            defer { bytes.task.cancel() }
            guard let httpResponse = response as? HTTPURLResponse,
                  (200..<400).contains(httpResponse.statusCode),
                  Self.allowsFetchResponseURL(httpResponse.url) else {
                failed.insert(key)
                return
            }

            var data = Data()
            data.reserveCapacity(Self.maximumBodyBytes)
            for try await byte in bytes {
                if data.count == Self.maximumBodyBytes {
                    bytes.task.cancel()
                    break
                }
                data.append(byte)
            }
            guard let html = String(data: data, encoding: .utf8),
                  let title = Self.extractTitle(from: html),
                  !title.isEmpty else {
                failed.insert(key)
                return
            }
            workspace.linksState.setFetchedTitle(title, for: entry.id)
        } catch {
            failed.insert(key)
        }
    }

    nonisolated static func mayFetchTitle(url: String, hostKey: String?) -> Bool {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else { return false }
        guard let hostKey else { return false }
        let host = CapturedLinkHostPolicy.hostPart(of: hostKey)
        return !CapturedLinkHostPolicy.isPrivateOrLocalHost(host)
    }

    nonisolated static func allowsRedirect(to url: URL?) async -> Bool {
        guard allowsFetchResponseURL(url), let host = url?.host() else { return false }
        return await hostResolvesOnlyToPublicAddresses(host)
    }

    nonisolated static func hostResolvesOnlyToPublicAddresses(_ host: String) async -> Bool {
        let normalized = normalizedHost(host)
        guard !normalized.isEmpty else { return false }
        if let literalDecision = publicLiteralAddressDecision(for: normalized) {
            return literalDecision
        }
        return await Task.detached(priority: .utility) {
            resolveHostToPublicAddressesOnly(normalized)
        }.value
    }

    nonisolated private static func allowsFetchResponseURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let hostKey = CapturedLinkHostPolicy.hostKey(for: url.absoluteString) else {
            return false
        }
        let host = CapturedLinkHostPolicy.hostPart(of: hostKey)
        return !CapturedLinkHostPolicy.isPrivateOrLocalHost(host)
    }

    nonisolated private static func normalizedHost(_ host: String) -> String {
        host
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    nonisolated private static func publicLiteralAddressDecision(for host: String) -> Bool? {
        var ipv4 = in_addr()
        if host.withCString({ Darwin.inet_aton($0, &ipv4) }) != 0 {
            let value = UInt32(bigEndian: ipv4.s_addr)
            let octets = [
                UInt8((value >> 24) & 0xFF),
                UInt8((value >> 16) & 0xFF),
                UInt8((value >> 8) & 0xFF),
                UInt8(value & 0xFF),
            ]
            return !CapturedLinkHostPolicy.isPrivateOrLocalIPv4Address(octets)
        }

        var ipv6 = in6_addr()
        if host.withCString({ Darwin.inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            let bytes = withUnsafeBytes(of: ipv6) { Array($0) }
            return !CapturedLinkHostPolicy.isPrivateOrLocalIPv6Address(bytes)
        }
        return nil
    }

    nonisolated private static func resolveHostToPublicAddressesOnly(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var result: UnsafeMutablePointer<addrinfo>?
        guard Darwin.getaddrinfo(host, nil, &hints, &result) == 0,
              let result else {
            return false
        }
        defer { Darwin.freeaddrinfo(result) }

        var sawAddress = false
        var cursor: UnsafeMutablePointer<addrinfo>? = result
        while let current = cursor {
            if let address = current.pointee.ai_addr {
                sawAddress = true
                if socketAddressIsPrivateOrLocal(address) {
                    return false
                }
            }
            cursor = current.pointee.ai_next
        }
        return sawAddress
    }

    nonisolated private static func socketAddressIsPrivateOrLocal(_ address: UnsafePointer<sockaddr>) -> Bool {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                let value = UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
                return CapturedLinkHostPolicy.isPrivateOrLocalIPv4Address([
                    UInt8((value >> 24) & 0xFF),
                    UInt8((value >> 16) & 0xFF),
                    UInt8((value >> 8) & 0xFF),
                    UInt8(value & 0xFF),
                ])
            }
        case AF_INET6:
            return address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                CapturedLinkHostPolicy.isPrivateOrLocalIPv6Address(
                    withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                )
            }
        default:
            return true
        }
    }

    nonisolated static func extractTitle(from html: String) -> String? {
        guard let openRange = html.range(of: "<title", options: [.caseInsensitive]),
              let closeOfOpen = html[openRange.upperBound...].firstIndex(of: ">"),
              let closeRange = html.range(
                of: "</title>",
                options: [.caseInsensitive],
                range: closeOfOpen..<html.endIndex
              ) else {
            return nil
        }
        let raw = html[html.index(after: closeOfOpen)..<closeRange.lowerBound]
        return raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class LinkTitleRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        Task {
            let allowed = await LinkTitleFetcher.allowsRedirect(to: request.url)
            completionHandler(allowed ? request : nil)
        }
    }
}
