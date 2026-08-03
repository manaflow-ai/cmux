import Foundation

/// Supplies deterministic syscall failures to package tests.
///
/// Production transports use the disabled value. Keeping this seam internal
/// avoids exposing test behavior through the package's public API.
protocol SocketTransportFaultInjecting: Sendable {
    func errnoCode(stage: String, path: String) -> Int32?
}

struct SocketTransportFaultInjection: Sendable {
    static let disabled = Self(injector: nil)

    let injector: (any SocketTransportFaultInjecting)?

    func errnoCode(stage: String, path: String) -> Int32? {
        injector?.errnoCode(stage: stage, path: path)
    }
}

extension SocketTransport {
    /// Creates a production-equivalent transport with deterministic test faults.
    init(
        clientReadTimeout: TimeInterval = 30,
        clientWriteTimeout: TimeInterval = 5,
        listenBacklog: Int32 = 128,
        pathLockSuffix: String = ".lock",
        pathLockReusableMarker: String = "cmux-socket-lock-v1\n",
        faultInjector: any SocketTransportFaultInjecting
    ) {
        self.clientReadTimeout = clientReadTimeout
        self.clientWriteTimeout = clientWriteTimeout
        self.listenBacklog = listenBacklog
        self.pathLockSuffix = pathLockSuffix
        self.pathLockReusableMarker = pathLockReusableMarker
        self.faultInjection = SocketTransportFaultInjection(injector: faultInjector)
    }

    /// Returns a scripted test error without changing production syscall behavior.
    func injectedErrnoCode(stage: String, path: String) -> Int32? {
        faultInjection.errnoCode(stage: stage, path: path)
    }
}
