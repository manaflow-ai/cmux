import Foundation
import Network
import Security

/// Bridges NWConnection's callback API into one cancellable async response.
///
/// SAFETY: all mutable fields are confined to `queue`; cancellation only calls
/// NWConnection's thread-safe `cancel()`, whose terminal callback returns to that
/// same queue before the continuation is resumed.
final class BrowserPinnedHTTPConnection: @unchecked Sendable {
    private let request: BrowserPageMetadataRequest
    private let maximumWireBytes: Int
    private let queue = DispatchQueue(label: "dev.cmux.browser-page-metadata", qos: .utility)
    private let connection: NWConnection
    private var continuation: CheckedContinuation<Data?, Never>?
    private var wireData = Data()
    private var completed = false

    init(request: BrowserPageMetadataRequest, endpointHost: NWEndpoint.Host, maximumWireBytes: Int) {
        self.request = request
        self.maximumWireBytes = maximumWireBytes

        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 5
        let parameters: NWParameters
        if request.scheme == "https" {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, request.host)
            sec_protocol_options_set_verify_block(
                tls.securityProtocolOptions,
                { [serverName = request.host] _, trust, complete in
                    let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                    SecTrustSetPolicies(secTrust, SecPolicyCreateSSL(true, serverName as CFString))
                    var error: CFError?
                    complete(SecTrustEvaluateWithError(secTrust, &error))
                },
                queue
            )
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        parameters.includePeerToPeer = false
        let port = NWEndpoint.Port(rawValue: request.port)!
        connection = NWConnection(to: .hostPort(host: endpointHost, port: port), using: parameters)
    }

    func fetch() async -> Data? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async { [weak self] in
                    self?.start(continuation)
                }
            }
        } onCancel: { [connection] in
            connection.cancel()
        }
    }

    private func start(_ continuation: CheckedContinuation<Data?, Never>) {
        guard !completed else {
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                sendRequest()
            case .failed, .cancelled:
                finish(nil)
            case .setup, .preparing, .waiting:
                break
            @unknown default:
                finish(nil)
            }
        }
        connection.start(queue: queue)
    }

    private func sendRequest() {
        connection.send(content: request.bytes, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            guard error == nil else {
                finish(nil)
                return
            }
            receiveNext()
        })
    }

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 32 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard error == nil else {
                finish(nil)
                return
            }
            if let data, !data.isEmpty {
                guard data.count <= maximumWireBytes,
                      wireData.count <= maximumWireBytes - data.count else {
                    finish(nil)
                    return
                }
                wireData.append(data)
            }
            if isComplete {
                finish(wireData)
            } else {
                receiveNext()
            }
        }
    }

    private func finish(_ data: Data?) {
        guard !completed else { return }
        completed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        continuation?.resume(returning: data)
        continuation = nil
    }
}
