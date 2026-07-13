import Darwin
import Foundation
import Network
import Security

struct MarkdownRemoteImageFetchResult {
    let data: Data
    let mimeType: String
}

enum MarkdownRemoteImageSecurity {
    static let maximumRemoteImageBytes = 8 * 1024 * 1024

    static func remoteImageURL(from requestURL: URL) -> URL? {
        guard requestURL.scheme?.lowercased() == MarkdownWebRenderer.remoteImageURLScheme,
              let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false),
              let rawRemoteURL = components.queryItems?.first(where: { $0.name == "url" })?.value,
              let remoteURL = URL(string: rawRemoteURL),
              isPotentiallySafeRemoteImageURL(remoteURL) else {
            return nil
        }
        return remoteURL
    }

    static func isPotentiallySafeRemoteImageURL(_ url: URL) -> Bool {
        isSafeRemoteImageURL(url, resolveHost: false)
    }

    static func isSafeRemoteImageURL(_ url: URL, resolveHost: Bool = true) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              url.port == nil || url.port == 443,
              let host = url.host(percentEncoded: false),
              isAllowedHostNameOrLiteral(host) else {
            return false
        }
        return !resolveHost || hostResolvesOnlyToAllowedAddresses(host)
    }

    static func pinnedFetchTargets(for url: URL) -> [MarkdownRemoteImageFetchTarget] {
        guard isPotentiallySafeRemoteImageURL(url),
              let host = url.host(percentEncoded: false),
              let endpoints = resolvedAllowedEndpoints(for: host),
              !endpoints.isEmpty else {
            return []
        }
        return endpoints.map {
            MarkdownRemoteImageFetchTarget(url: url, serverName: host, endpointHost: $0, port: 443)
        }
    }

    static func pathAndQuery(for url: URL) -> String {
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var value = components?.percentEncodedPath.isEmpty == false ? components?.percentEncodedPath ?? "/" : "/"
        if let query = components?.percentEncodedQuery, !query.isEmpty {
            value += "?\(query)"
        }
        return value
    }

    static func requestBytes(for url: URL, host: String) -> Data? {
        guard let hostHeader = httpHostHeaderValue(for: host) else { return nil }
        let request = [
            "GET \(pathAndQuery(for: url)) HTTP/1.1",
            "Host: \(hostHeader)",
            "Accept: image/png,image/jpeg,image/gif,image/webp,image/avif;q=0.9,image/svg+xml;q=0.9,*/*;q=0.1",
            "User-Agent: cmux-markdown-image-loader",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return request.data(using: .utf8)
    }

    static func remoteImageConsentHost(for url: URL) -> String? {
        guard isPotentiallySafeRemoteImageURL(url),
              let host = url.host(percentEncoded: false) else {
            return nil
        }
        let normalized = normalizedRemoteImageHost(host)
        return normalized.isEmpty ? nil : normalized
    }

    static func canonicalImageMIMEType(_ raw: String?) -> String? {
        let mimeType = String(raw ?? "")
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        switch mimeType {
        case "image/png":
            return "image/png"
        case "image/jpeg", "image/jpg":
            return "image/jpeg"
        case "image/gif":
            return "image/gif"
        case "image/webp":
            return "image/webp"
        case "image/avif":
            return "image/avif"
        case "image/svg+xml":
            return "image/svg+xml"
        default:
            return nil
        }
    }

    private static func normalizedRemoteImageHost(_ rawHost: String) -> String {
        rawHost
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]").union(.whitespacesAndNewlines))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }

    private static func isAllowedHostNameOrLiteral(_ rawHost: String) -> Bool {
        let host = normalizedRemoteImageHost(rawHost)
        guard !host.isEmpty else { return false }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if host == "local" || host.hasSuffix(".local") { return false }
        if let bytes = ipv4Bytes(host) {
            return isAllowedIPv4Address(bytes)
        }
        if let bytes = ipv6Bytes(host) {
            return isAllowedIPv6Address(bytes)
        }
        return true
    }

    private static func hostResolvesOnlyToAllowedAddresses(_ rawHost: String) -> Bool {
        guard let endpoints = resolvedAllowedEndpoints(for: rawHost) else { return false }
        return !endpoints.isEmpty
    }

    private static func resolvedAllowedEndpoints(for rawHost: String) -> [NWEndpoint.Host]? {
        let host = rawHost.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if let bytes = ipv4Bytes(host) {
            guard isAllowedIPv4Address(bytes),
                  let endpoint = ipv4Endpoint(bytes) else { return nil }
            return [endpoint]
        }
        if let bytes = ipv6Bytes(host) {
            guard isAllowedIPv6Address(bytes),
                  let endpoint = ipv6Endpoint(bytes) else { return nil }
            return [endpoint]
        }

        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        var endpoints: [NWEndpoint.Host] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ai_next }
            guard let address = current.pointee.ai_addr else { continue }
            switch current.pointee.ai_family {
            case AF_INET:
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin_addr.s_addr) { Array($0) }
                }
                guard isAllowedIPv4Address(bytes),
                      let endpoint = ipv4Endpoint(bytes) else { return nil }
                endpoints.append(endpoint)
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                    withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) }
                }
                guard isAllowedIPv6Address(bytes),
                      let endpoint = ipv6Endpoint(bytes) else { return nil }
                endpoints.append(endpoint)
            default:
                continue
            }
        }
        var seen = Set<String>()
        return endpoints.filter { seen.insert(String(describing: $0)).inserted }
    }

    private static func ipv4Bytes(_ host: String) -> [UInt8]? {
        var address = in_addr()
        let result = host.withCString { inet_pton(AF_INET, $0, &address) }
        guard result == 1 else { return nil }
        return Array(withUnsafeBytes(of: address.s_addr) { $0 })
    }

    private static func ipv6Bytes(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let result = host.withCString { inet_pton(AF_INET6, $0, &address) }
        guard result == 1 else { return nil }
        return Array(withUnsafeBytes(of: address) { $0 })
    }

    private static func isAllowedIPv4Address(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        if first == 0 { return false }
        if first == 10 { return false }
        if first == 100 && (64...127).contains(second) { return false }
        if first == 127 { return false }
        if first == 169 && second == 254 { return false }
        if first == 172 && (16...31).contains(second) { return false }
        if first == 192 && second == 0 { return false }
        if first == 192 && second == 168 { return false }
        if first == 198 && (18...19).contains(second) { return false }
        if first >= 224 { return false }
        return true
    }

    private static func isAllowedIPv6Address(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return false }
        if bytes[0] & 0xfe == 0xfc { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return false }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0xc0 { return false }
        if bytes[0] == 0xff { return false }
        if bytes[0..<12].allSatisfy({ $0 == 0 }) { return false }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isAllowedIPv4Address(Array(bytes[12..<16]))
        }
        return true
    }

    private static func ipv4Endpoint(_ bytes: [UInt8]) -> NWEndpoint.Host? {
        guard bytes.count == 4 else { return nil }
        let value = bytes.map(String.init).joined(separator: ".")
        guard let address = IPv4Address(value) else { return nil }
        return .ipv4(address)
    }

    private static func ipv6Endpoint(_ bytes: [UInt8]) -> NWEndpoint.Host? {
        guard bytes.count == 16 else { return nil }
        var address = in6_addr()
        withUnsafeMutableBytes(of: &address) { buffer in
            for index in bytes.indices {
                buffer[index] = bytes[index]
            }
        }
        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        return withUnsafePointer(to: &address) { pointer in
            guard inet_ntop(AF_INET6, pointer, &output, socklen_t(output.count)) != nil else {
                return nil
            }
            let value = String(cString: output)
            guard let networkAddress = IPv6Address(value) else { return nil }
            return .ipv6(networkAddress)
        }
    }

    private static func isSafeHTTPHeaderValue(_ value: String) -> Bool {
        value.utf8.allSatisfy { byte in
            byte >= 0x21 && byte != 0x7f
        }
    }

    private static func httpHostHeaderValue(for rawHost: String) -> String? {
        let host = normalizedRemoteImageHost(rawHost)
        guard isSafeHTTPHeaderValue(host) else { return nil }
        if ipv6Bytes(host) != nil {
            return "[\(host)]"
        }
        return host
    }
}

struct MarkdownRemoteImageFetchTarget {
    let url: URL
    let serverName: String
    let endpointHost: NWEndpoint.Host
    let port: UInt16
}

enum MarkdownRemoteImageFetcher {
    static func fetch(_ url: URL) async -> MarkdownRemoteImageFetchResult? {
        guard !Task.isCancelled,
              let approvedHost = MarkdownRemoteImageSecurity.remoteImageConsentHost(for: url) else {
            return nil
        }
        return await fetch(url, approvedHost: approvedHost, redirectDepth: 0)
    }

    private static func fetch(
        _ url: URL,
        approvedHost: String,
        redirectDepth: Int
    ) async -> MarkdownRemoteImageFetchResult? {
        guard !Task.isCancelled,
              redirectDepth <= 3 else { return nil }
        let targets = MarkdownRemoteImageSecurity.pinnedFetchTargets(for: url)
        guard !Task.isCancelled else { return nil }
        for target in targets {
            guard !Task.isCancelled else { return nil }
            let loader = MarkdownPinnedRemoteImageLoader(
                target: target,
                maximumBytes: MarkdownRemoteImageSecurity.maximumRemoteImageBytes
            )
            switch await loader.fetch() {
            case .image(let result):
                guard !Task.isCancelled else { return nil }
                return result
            case .redirect(let redirectURL):
                guard !Task.isCancelled,
                      let resolvedRedirect = URL(string: redirectURL.absoluteString, relativeTo: url)?.absoluteURL,
                      MarkdownRemoteImageSecurity.remoteImageConsentHost(for: resolvedRedirect) == approvedHost else {
                    return nil
                }
                return await fetch(
                    resolvedRedirect,
                    approvedHost: approvedHost,
                    redirectDepth: redirectDepth + 1
                )
            case .none:
                continue
            }
        }
        return nil
    }
}

private enum MarkdownRemoteImageLoadOutcome {
    case image(MarkdownRemoteImageFetchResult)
    case redirect(URL)
}

private final class MarkdownPinnedRemoteImageLoader {
    private let maximumBytes: Int
    private let target: MarkdownRemoteImageFetchTarget
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.cmux.markdown-remote-image", qos: .userInitiated)
    private var rawBody = Data()
    private var mimeType = "image/png"
    private var completion: ((MarkdownRemoteImageLoadOutcome?) -> Void)?
    private var connection: NWConnection?
    private var headerParsed = false
    private var usesChunkedTransfer = false
    private var expectedBodyBytes: Int?
    private var timeoutWorkItem: DispatchWorkItem?
    private var completed = false

    init(target: MarkdownRemoteImageFetchTarget, maximumBytes: Int) {
        self.target = target
        self.maximumBytes = maximumBytes
    }

    func fetch() async -> MarkdownRemoteImageLoadOutcome? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                start { outcome in
                    continuation.resume(returning: outcome)
                }
            }
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        finish(nil)
    }

    private func start(completion: @escaping (MarkdownRemoteImageLoadOutcome?) -> Void) {
        guard let requestData = MarkdownRemoteImageSecurity.requestBytes(
            for: target.url,
            host: target.serverName
        ) else {
            completion(nil)
            return
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, target.serverName)
        sec_protocol_options_set_verify_block(
            tls.securityProtocolOptions,
            { [serverName = target.serverName] _, trust, complete in
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                let policy = SecPolicyCreateSSL(true, serverName as CFString)
                SecTrustSetPolicies(secTrust, policy)
                var error: CFError?
                complete(SecTrustEvaluateWithError(secTrust, &error))
            },
            queue
        )

        let parameters = NWParameters(tls: tls)
        parameters.includePeerToPeer = false
        guard let endpointPort = NWEndpoint.Port(rawValue: target.port) else {
            completion(nil)
            return
        }
        let connection = NWConnection(to: .hostPort(host: target.endpointHost, port: endpointPort), using: parameters)
        let timeout = DispatchWorkItem { [weak self] in
            self?.finish(nil)
        }
        lock.lock()
        guard !completed else {
            lock.unlock()
            completion(nil)
            return
        }
        self.connection = connection
        self.completion = completion
        timeoutWorkItem = timeout
        lock.unlock()

        queue.asyncAfter(deadline: .now() + 15, execute: timeout)
        connection.stateUpdateHandler = { [weak self] (state: NWConnection.State) in
            switch state {
            case .ready:
                self?.send(requestData)
            case .failed, .cancelled:
                self?.finish(nil)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func send(_ requestData: Data) {
        currentConnection()?.send(content: requestData, completion: .contentProcessed { [weak self] error in
            guard error == nil else {
                self?.finish(nil)
                return
            }
            self?.receiveNext()
        })
    }

    private func receiveNext() {
        currentConnection()?.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if error != nil {
                finish(nil)
                return
            }

            if let data, !data.isEmpty {
                switch process(data) {
                case .continue:
                    break
                case .finish(let outcome):
                    finish(outcome)
                    return
                case .fail:
                    finish(nil)
                    return
                }
            }

            if isComplete {
                finish(finalOutcome())
                return
            }
            receiveNext()
        }
    }

    private enum ProcessResult {
        case `continue`
        case finish(MarkdownRemoteImageLoadOutcome)
        case fail
    }

    private func process(_ data: Data) -> ProcessResult {
        rawBody.append(data)
        if !headerParsed {
            guard let delimiter = rawBody.range(of: Data([13, 10, 13, 10])) else {
                return rawBody.count > 64 * 1024 ? .fail : .continue
            }
            let headerData = rawBody[..<delimiter.lowerBound]
            let remaining = rawBody[delimiter.upperBound...]
            rawBody = Data(remaining)
            switch parseHeaders(headerData) {
            case .continue:
                headerParsed = true
            case .finish(let outcome):
                return .finish(outcome)
            case .fail:
                return .fail
            }
        }

        if rawBody.count > maximumBytes + 64 * 1024 {
            return .fail
        }
        if !usesChunkedTransfer, rawBody.count > maximumBytes {
            return .fail
        }
        if !usesChunkedTransfer, let expectedBodyBytes, rawBody.count >= expectedBodyBytes {
            rawBody = Data(rawBody.prefix(expectedBodyBytes))
            guard let outcome = finalOutcome() else { return .fail }
            return .finish(outcome)
        }
        return .continue
    }

    private func parseHeaders(_ headerData: Data) -> ProcessResult {
        guard let rawHeaders = String(data: headerData, encoding: .isoLatin1) else {
            return .fail
        }
        let lines = rawHeaders.components(separatedBy: "\r\n")
        guard let statusLine = lines.first else { return .fail }
        let statusParts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard statusParts.count >= 2,
              let statusCode = Int(statusParts[1]) else {
            return .fail
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        if (300..<400).contains(statusCode),
           let location = headers["location"],
           let redirectURL = URL(string: location, relativeTo: target.url)?.absoluteURL,
           MarkdownRemoteImageSecurity.isPotentiallySafeRemoteImageURL(redirectURL) {
            return .finish(.redirect(redirectURL))
        }

        guard (200..<300).contains(statusCode),
              let responseMIMEType = MarkdownRemoteImageSecurity.canonicalImageMIMEType(headers["content-type"]) else {
            return .fail
        }

        if let transferEncoding = headers["transfer-encoding"]?.lowercased(),
           transferEncoding.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "chunked" }) {
            usesChunkedTransfer = true
        }

        if let contentLength = headers["content-length"].flatMap(Int.init) {
            guard contentLength >= 0, contentLength <= maximumBytes else { return .fail }
            expectedBodyBytes = contentLength
        }

        mimeType = responseMIMEType
        return .continue
    }

    private func finalOutcome() -> MarkdownRemoteImageLoadOutcome? {
        guard headerParsed else { return nil }
        let body: Data
        if usesChunkedTransfer {
            guard let decoded = MarkdownHTTPChunkedBodyDecoder.decode(
                rawBody,
                maximumBytes: maximumBytes
            ) else {
                return nil
            }
            body = decoded
        } else {
            if let expectedBodyBytes, rawBody.count != expectedBodyBytes {
                return nil
            }
            body = rawBody
        }
        guard body.count <= maximumBytes else { return nil }
        return .image(MarkdownRemoteImageFetchResult(data: body, mimeType: mimeType))
    }

    private func currentConnection() -> NWConnection? {
        lock.lock()
        let value = connection
        lock.unlock()
        return value
    }

    private func finish(_ outcome: MarkdownRemoteImageLoadOutcome?) {
        let callback: ((MarkdownRemoteImageLoadOutcome?) -> Void)?
        let connectionToCancel: NWConnection?
        let timeoutToCancel: DispatchWorkItem?
        lock.lock()
        guard !completed else {
            lock.unlock()
            return
        }
        completed = true
        callback = completion
        completion = nil
        connectionToCancel = connection
        connection = nil
        timeoutToCancel = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()

        timeoutToCancel?.cancel()
        connectionToCancel?.cancel()
        callback?(outcome)
    }
}

enum MarkdownHTTPChunkedBodyDecoder {
    static func decode(_ data: Data, maximumBytes: Int) -> Data? {
        let bytes = Array(data)
        var offset = 0
        var decoded = Data()

        while offset < bytes.count {
            guard let lineEnd = crlfIndex(in: bytes, from: offset) else { return nil }
            let sizeLineBytes = bytes[offset..<lineEnd]
            guard let sizeLine = String(bytes: sizeLineBytes, encoding: .ascii) else { return nil }
            let sizeToken = sizeLine.split(separator: ";", maxSplits: 1).first ?? ""
            guard let size = Int(sizeToken.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }
            offset = lineEnd + 2
            if size == 0 {
                return decoded
            }
            let remainingBytes = bytes.count - offset
            guard size >= 0,
                  size <= maximumBytes,
                  decoded.count <= maximumBytes - size,
                  remainingBytes >= 2,
                  size <= remainingBytes - 2 else {
                return nil
            }
            let chunkEnd = offset + size
            guard bytes[chunkEnd] == 13,
                  bytes[chunkEnd + 1] == 10 else {
                return nil
            }
            decoded.append(contentsOf: bytes[offset..<offset + size])
            guard decoded.count <= maximumBytes else { return nil }
            offset += size + 2
        }
        return nil
    }

    private static func crlfIndex(in bytes: [UInt8], from offset: Int) -> Int? {
        guard offset < bytes.count else { return nil }
        var index = offset
        while index + 1 < bytes.count {
            if bytes[index] == 13, bytes[index + 1] == 10 {
                return index
            }
            index += 1
        }
        return nil
    }
}
