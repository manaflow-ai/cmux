import CmuxFoundation
import Foundation

/// Fetches HTML page titles through validated, IP-pinned connections.
public actor BrowserPageMetadataService: BrowserPageMetadataFetching {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let addressPolicy: NetworkAddressPolicy
    private let resolver: any BrowserPageMetadataResolving
    private let transport: any BrowserPageMetadataTransporting
    private let titleExtractor: BrowserHTMLTitleExtractor
    private let operationTimeout: Duration
    private let sleep: Sleep
    private let maximumBodyBytes: Int
    private let maximumRedirects: Int

    /// Creates the production page-metadata service.
    public init() {
        let addressPolicy = NetworkAddressPolicy()
        self.addressPolicy = addressPolicy
        self.resolver = BrowserPageMetadataDNSResolver(addressPolicy: addressPolicy)
        self.transport = BrowserPageMetadataTransport()
        self.titleExtractor = BrowserHTMLTitleExtractor()
        self.operationTimeout = .seconds(5)
        self.sleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
        self.maximumBodyBytes = 65_536
        self.maximumRedirects = 3
    }

    init(
        addressPolicy: NetworkAddressPolicy = NetworkAddressPolicy(),
        resolver: any BrowserPageMetadataResolving,
        transport: any BrowserPageMetadataTransporting,
        operationTimeout: Duration = .seconds(5),
        maximumBodyBytes: Int = 65_536,
        maximumRedirects: Int = 3,
        sleep: @escaping Sleep = { duration in
            try await ContinuousClock().sleep(for: duration)
        }
    ) {
        self.addressPolicy = addressPolicy
        self.resolver = resolver
        self.transport = transport
        self.titleExtractor = BrowserHTMLTitleExtractor()
        self.operationTimeout = operationTimeout
        self.sleep = sleep
        self.maximumBodyBytes = maximumBodyBytes
        self.maximumRedirects = maximumRedirects
    }

    /// Fetches a title without allowing DNS to change the dialed endpoint.
    ///
    /// - Parameter url: The HTTP or HTTPS page URL.
    /// - Returns: A bounded, trimmed HTML title or `nil` when validation or fetching fails.
    /// - Throws: `CancellationError` when the caller cancels the operation.
    public func title(for url: URL) async throws -> String? {
        let sleep = sleep
        let operationTimeout = operationTimeout
        return try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await self.fetchTitleFollowingRedirects(for: url)
            }
            group.addTask {
                try await sleep(operationTimeout)
                return nil
            }
            let first = try await group.next() ?? nil
            group.cancelAll()
            try Task.checkCancellation()
            return first
        }
    }

    private func fetchTitleFollowingRedirects(for url: URL) async throws -> String? {
        var currentURL = url
        for redirectCount in 0...maximumRedirects {
            try Task.checkCancellation()
            guard let request = BrowserPageMetadataRequest(
                url: currentURL,
                addressPolicy: addressPolicy
            ) else {
                return nil
            }
            let resolvedAddresses = await resolver.addresses(for: request.host)
            try Task.checkCancellation()
            let addresses = Array(resolvedAddresses.prefix(4))
            guard !addresses.isEmpty,
                  addresses.allSatisfy(allows) else {
                return nil
            }

            var response: BrowserPageMetadataHTTPResponse?
            for address in addresses {
                try Task.checkCancellation()
                response = await transport.response(
                    for: request,
                    address: address,
                    maximumBodyBytes: maximumBodyBytes
                )
                try Task.checkCancellation()
                if response != nil { break }
            }
            guard let response else { return nil }

            if let location = response.redirectLocation {
                guard redirectCount < maximumRedirects,
                      let redirectURL = URL(string: location, relativeTo: currentURL)?.absoluteURL else {
                    return nil
                }
                currentURL = redirectURL
                continue
            }
            guard (200..<300).contains(response.statusCode),
                  responseIsHTML(response),
                  let title = titleExtractor.title(from: response.body) else {
                return nil
            }
            return String(title.prefix(2_048))
        }
        return nil
    }

    private func allows(_ address: BrowserPageMetadataResolvedAddress) -> Bool {
        switch address.family {
        case .ipv4:
            return addressPolicy.allowsPublicIPv4Address(address.bytes)
        case .ipv6:
            return addressPolicy.allowsPublicIPv6Address(address.bytes)
        }
    }

    private func responseIsHTML(_ response: BrowserPageMetadataHTTPResponse) -> Bool {
        guard let rawContentType = response.headers["content-type"] else { return true }
        let contentType = rawContentType
            .split(separator: ";", maxSplits: 1)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return contentType == "text/html" || contentType == "application/xhtml+xml"
    }
}
