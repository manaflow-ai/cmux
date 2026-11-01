import AppKit
import CmuxNextCompat
import CmuxNextDaemon
@testable import CmuxNextDaemonRecovery
@testable import CmuxNextDaemonService
import CmuxNextDesign
import CmuxNextTestSupport
import Foundation
import Testing

/// Restore fuzz h2, the screen: a window that shows content had no Retry or Restart after the
/// local cmux-tui died, because the launch window's controls show only before the first workspace.
/// `DaemonRecoveryNotice` puts Restart cmux-tui and the reason (a full disk named) in that window.
///
/// The app's real service runs on a stand-in daemon behind a bridge (never a real daemon, never a
/// signal): it connects, then exits on `test-die` (the app reads EOF). Its restart runs a stand-in
/// `cmux-tui` whose `server ensure` fails as a start on a full disk fails.
@MainActor @Suite(.serialized, .timeLimit(.minutes(2)), .closesItsWindows)
struct DaemonRecoveryNoticeTests {
    @MainActor private final class RecordingHost: CmuxToastHosting {
        func show(_ toast: CmuxToastView, in window: NSWindow, slot: Int, appearing: Bool, windowGone: @escaping () -> Void) {}
        func move(_ toast: CmuxToastView, to slot: Int) {}
        func hide(_ toast: CmuxToastView, animated: Bool) {}
    }

    private nonisolated struct Die: DaemonRequest {
        typealias Response = EmptyResponse
        static let command = "test-die"
    }

    private nonisolated final class Counter: Sendable {
        private let value = Mutex(0)
        /// Adds one and returns the count before it.
        func increment() -> Int {
            value.withLock { count in
                defer { count += 1 }
                return count
            }
        }
    }

    private nonisolated static let daemonScript = #"""
    import json, sys
    print('{"ok":true}', file=sys.stderr, flush=True)
    for line in sys.stdin:
        frame = json.loads(line)
        if frame.get('cmd') == 'test-die':
            sys.exit(0)
        if frame.get('cmd') == 'identify':
            data = {'app': 'cmux-tui', 'protocol': 12, 'generation': 'notice-test', 'pid': 4242, 'capabilities': []}
        else:
            data = {}
        print(json.dumps({'id': frame.get('id'), 'ok': True, 'data': data}), flush=True)
    """#

    private static let diskFullEnsure =
        #"{"code":"server.spawn_failed","message":"could not start the session owner: No space left on device (os error 28)","details":{},"retryable":false}"#

    /// Test-harness poll for steps on other tasks; the limit is only a failure deadline.
    private static func eventually(_ done: () -> Bool) async -> Bool {
        for _ in 0..<1000 where !done() {
            try? await Task.sleep(for: .milliseconds(10))
        }
        return done()
    }

    @Test func aWindowWithContentOffersRestartWithTheFullDiskWhenTheDaemonDies() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cn-notice-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("cmux-tui")
        try """
        #!/bin/sh
        case " $* " in
        *" server status "*) exit 1 ;;
        *" server ensure "*) echo '\(Self.diskFullEnsure)' >&2; exit 3 ;;
        esac
        exit 64
        """.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cn-notice-\(UUID().uuidString.prefix(8).lowercased())",
                                 stateDirectory: root.appendingPathComponent("state"), binaryIsBundled: true),
            environment: { ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"] })

        let service = DaemonService()
        service.recovery.restartsUnresponsiveOwner = { false }
        service.recovery.attach(launcher, wake: service.retryWake)
        let socket = root.appendingPathComponent("cmux.sock").path
        let starts = Counter()
        let endpoint = launcher.endpointProvider
        // Made here: the bridge's maker is main-actor, the endpoint provider is not.
        let first = DaemonEndpoint(socketPath: socket, bridge: .fakePython(["-c", Self.daemonScript]))
        let connection = DaemonConnection(configuration: .init(requiredCapabilities: [], terminalEnvironment: nil)) {
            // The first start reaches the stand-in daemon; every restart after it runs the failing ensure.
            guard starts.increment() == 0 else { return try await endpoint() }
            return first
        }
        service.start(makeConnection: { connection })
        defer { service.shutdownConnection() }
        try #require(await Self.eventually { service.startup == .connected }, "the stand-in daemon never connected")

        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let toasts = CmuxToastCenter(host: RecordingHost())
        let notice = DaemonRecoveryNotice(daemon: service, toasts: toasts, window: { [window] in window })
        notice.start()
        defer { notice.stop() }
        #expect(toasts.toasts(in: window).isEmpty, "a notice while the daemon is connected")

        // The kill: the stand-in exits on this request, and the restart's ensure fails on the full disk.
        _ = try? await connection.request(Die())
        let shown = await Self.eventually { !toasts.toasts(in: window).isEmpty }
        let toast = try #require(toasts.toasts(in: window).first, "no notice after the daemon died (shown: \(shown))")
        #expect(toast.id == DaemonRecoveryNotice.toastID)
        #expect(toast.message == DaemonRecoveryStrings.diskFull, "the notice does not name the full disk: \(toast.message)")
        #expect(toast.action?.title == DaemonRecoveryStrings.restart)
        // The detail is the launcher's raw failure (the stand-in's own text, not a localized string).
        #expect(toast.detail?.contains("server.spawn_failed") == true, "the notice has not the raw failure: \(toast.detail ?? "none")")
        #expect(service.recovery.offersRestart)

        // Restart asks first, as the launch window's button does; cancelled, the notice shows again.
        #expect(toasts.runAction(id: DaemonRecoveryNotice.toastID, in: window))
        let asked = await Self.eventually {
            CmuxDialogCenter.shared.records.contains { $0.spec.identifier == DaemonRestartPrompt.identifier }
        }
        #expect(asked, "Restart cmux-tui did not ask before restarting")
        let question = try #require(CmuxDialogCenter.shared.records.last { $0.spec.identifier == DaemonRestartPrompt.identifier })
        let cancel = try #require(question.spec.cancelButton?.id)
        #expect(CmuxDialogCenter.shared.press(question.id, button: cancel))
        #expect(await Self.eventually { toasts.toasts(in: window).first?.id == DaemonRecoveryNotice.toastID },
                "a cancelled restart left the window with no way out")
        CmuxDialogCenter.shared.dismissAll()
    }
}
