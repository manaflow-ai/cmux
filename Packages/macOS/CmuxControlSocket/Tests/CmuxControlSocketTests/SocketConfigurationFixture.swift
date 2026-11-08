@testable import CmuxControlSocket
import Foundation
import os

/// Isolated live-server fixture for socket configuration behavior tests.
@MainActor
struct SocketConfigurationFixture: ~Copyable {
    let directory: URL
    let socketPath: String
    let notificationCenter: NotificationCenter
    let server: SocketControlServer
    private let password: OSAllocatedUnfairLock<(value: String?, readCount: Int)>
    private let authorizationChangeProbe: AuthorizationChangeStreamProbe

    init(effectivePassword: String? = nil) throws {
        let identifier = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scr-\(identifier)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        socketPath = directory.appendingPathComponent("cmux.sock").path
        notificationCenter = NotificationCenter()
        let password = OSAllocatedUnfairLock(
            initialState: (value: effectivePassword, readCount: 0)
        )
        self.password = password
        let authorizationChangeProbe = AuthorizationChangeStreamProbe()
        self.authorizationChangeProbe = authorizationChangeProbe
        let authorizationChanges = AsyncStream<Void>(unfolding: {
            await authorizationChangeProbe.next()
        })
        server = SocketControlServer(
            initialSocketPath: socketPath,
            notificationCenter: notificationCenter,
            effectivePasswordProvider: {
                password.withLock { state in
                    state.readCount += 1
                    return state.value
                }
            },
            authorizationChangeSignals: authorizationChanges,
            events: SocketControlServerEvents(
                breadcrumb: { _, _ in },
                failure: { _, _, _, _ in },
                listenerDidStart: { _, _ in },
                recordLastSocketPath: { _ in },
                pathMissingDetected: { _, _ in },
                rearmRequested: { _, _, _, _ in }
            )
        )
    }

    func setEffectivePassword(_ value: String?) {
        password.withLock { $0.value = value }
    }

    var passwordReadCount: Int {
        password.withLock { $0.readCount }
    }

    func signalExternalPasswordChangeAndWaitUntilConsumed() async {
        await authorizationChangeProbe.signalAndWaitUntilConsumed()
    }

    func shutdown() {
        authorizationChangeProbe.finish()
        server.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}
