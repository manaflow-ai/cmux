import AppKit
import CmuxBrowser
import Foundation

/// Records Chromium helper processes (GPU, network and other utility
/// processes, extension renderers) that end abnormally. Chromium restarts
/// them itself and CEF reports none of them per tab, so without this a GPU or
/// network-service crash leaves no trace (`debug.browser.crashes`). Tab
/// renderer ends are recorded by their panel instead.
///
/// Started by the first Chromium page this run; a WebKit-only session never
/// starts it. It stops when the app begins to terminate: Chromium then ends
/// every helper, with SIGKILL for any that do not exit in time, and those ends
/// are not crashes. (Chromium also SIGKILLs a retired helper that ignores its
/// SIGTERM; such an end is recorded as `killed`, not `crashed`.)
@MainActor
enum ChromiumHelperCrashWatch {
    private static var monitor: ChromiumChildProcessMonitor?
    private static var terminationObserver: (any NSObjectProtocol)?

    static func startIfNeeded(log: BrowserCrashLog = .app) {
        guard monitor == nil else { return }
        let monitor = ChromiumChildProcessMonitor { exit in
            guard let kind = exit.abnormalKind, exit.identity.processType != "renderer" || exit.identity.isExtension else {
                return
            }
            Task { @MainActor in
                log.append(BrowserCrashRecord(
                    processType: exit.identity.recordedType,
                    subType: exit.identity.subType,
                    pid: exit.pid,
                    kind: kind,
                    status: exit.status,
                    source: .process
                ))
            }
        }
        Self.monitor = monitor
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { stop() }
        }
        monitor.start()
    }

    /// Stops recording (quit). Idempotent.
    static func stop() {
        monitor?.stop()
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        terminationObserver = nil
    }
}
