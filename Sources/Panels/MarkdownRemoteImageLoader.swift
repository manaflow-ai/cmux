import CmuxFoundation
import Foundation
import Network
import Security

enum MarkdownRemoteImageFetcher {
    static func fetch(_ url: URL, security: MarkdownRemoteImageSecurity) async -> MarkdownRemoteImageFetchResult? {
        guard !Task.isCancelled,
              let approvedHost = security.remoteImageConsentHost(for: url) else {
            return nil
        }
        return await fetch(url, security: security, approvedHost: approvedHost, redirectDepth: 0)
    }

    private static func fetch(
        _ url: URL,
        security: MarkdownRemoteImageSecurity,
        approvedHost: String,
        redirectDepth: Int
    ) async -> MarkdownRemoteImageFetchResult? {
        guard !Task.isCancelled,
              redirectDepth <= 3 else { return nil }
        let targets = security.pinnedFetchTargets(for: url)
        guard !Task.isCancelled else { return nil }
        for target in targets {
            guard !Task.isCancelled else { return nil }
            let loader = MarkdownPinnedRemoteImageLoader(
                target: target,
                maximumBytes: MarkdownRemoteImageSecurity.maximumRemoteImageBytes,
                security: security
            )
            switch await loader.fetch() {
            case .image(let result):
                guard !Task.isCancelled else { return nil }
                return result
            case .redirect(let redirectURL):
                guard !Task.isCancelled,
                      let resolvedRedirect = URL(string: redirectURL.absoluteString, relativeTo: url)?.absoluteURL,
                      security.remoteImageConsentHost(for: resolvedRedirect) == approvedHost else {
                    return nil
                }
                return await fetch(
                    resolvedRedirect,
                    security: security,
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
    private let security: MarkdownRemoteImageSecurity
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

    init(target: MarkdownRemoteImageFetchTarget, maximumBytes: Int, security: MarkdownRemoteImageSecurity) {
        self.target = target
        self.maximumBytes = maximumBytes
        self.security = security
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
        guard let requestData = security.requestBytes(
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
           security.isPotentiallySafeRemoteImageURL(redirectURL) {
            return .finish(.redirect(redirectURL))
        }

        guard (200..<300).contains(statusCode),
              let responseMIMEType = security.canonicalImageMIMEType(headers["content-type"]) else {
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
            guard let decoded = HTTPChunkedBodyDecoder(maximumBytes: maximumBytes).decode(rawBody) else {
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
