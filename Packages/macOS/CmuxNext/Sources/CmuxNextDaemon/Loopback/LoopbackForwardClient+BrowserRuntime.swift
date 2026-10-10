import Foundation

/// Browser runtimes (`browser-runtime-v1`) on the forwarding connection:
/// the daemon starts the browser host on its machine, and the app reaches
/// the host's port with `open(host:port:)` on the same connection. A runtime
/// ends with this connection.
extension LoopbackForwardClient {
    /// A start waits for a cold browser (the daemon's own deadline is 45 s).
    static let runtimeStartTimeout: Duration = .seconds(50)

    public func browserRuntimeStatus() async throws(BrowserRuntimeError) -> BrowserRuntimeStatus {
        do {
            let transport = try await enabledTransport()
            return try await DaemonConnection.perform(BrowserRuntimeStatusRequest(), on: transport, timeout: requestTimeout)
        } catch {
            throw BrowserRuntimeError.from(error)
        }
    }

    /// Starts a browser on the machine, at `url` (http or https) when given.
    public func startBrowserRuntime(url: URL?) async throws(BrowserRuntimeError) -> BrowserRuntime {
        do {
            let transport = try await enabledTransport()
            return try await DaemonConnection.perform(BrowserRuntimeStartRequest(url: url?.absoluteString), on: transport,
                                                      timeout: Self.runtimeStartTimeout)
        } catch {
            throw BrowserRuntimeError.from(error)
        }
    }

    /// Stops a runtime this connection started (a lost connection already did).
    public func stopBrowserRuntime(_ runtime: UInt64) async {
        guard let transport = try? await enabledTransport() else { return }
        _ = try? await DaemonConnection.perform(BrowserRuntimeStopRequest(runtime: runtime), on: transport, timeout: requestTimeout)
    }

    private func enabledTransport() async throws -> LineTransport {
        let transport = try await liveTransport()
        guard runtimeEnabled else { throw BrowserRuntimeError.unsupported }
        return transport
    }
}
