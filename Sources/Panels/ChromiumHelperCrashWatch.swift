import CmuxBrowser
import Foundation

/// Records Chromium helper processes (GPU, network and other utility
/// processes, extension renderers) that end abnormally. Chromium restarts
/// them itself and CEF reports none of them per tab, so without this a GPU or
/// network-service crash leaves no trace (`debug.browser.crashes`). Tab
/// renderer ends are recorded by their panel instead.
///
/// Started by the first Chromium page this run; a WebKit-only session never
/// starts it. Quit-time helper ends are normal (SIGTERM) and not recorded.
@MainActor
enum ChromiumHelperCrashWatch {
    private static var monitor: ChromiumChildProcessMonitor?

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
        monitor.start()
    }
}
