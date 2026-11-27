import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// The app's hang watch, started once at launch (`CmuxMobileApp.init`): the main-thread
/// watchdog writing hang files through ``HangReports``, and a MetricKit subscriber collecting
/// `MXHangDiagnostic` payloads into the same directory.
public enum HangWatch {
    @MainActor private static var started: (watchdog: MainThreadHangWatchdog, reports: HangReports, metrics: AnyObject?)?

    /// The running watchdog (nil before ``start()``).
    @MainActor public static var watchdog: MainThreadHangWatchdog? { started?.watchdog }

    @MainActor
    public static func start(reports: HangReports = HangReports()) {
        guard started == nil else { return }
        let watchdog = MainThreadHangWatchdog()
        watchdog.onHang = { hang in reports.record(hang) }
        watchdog.start()
        started = (watchdog, reports, MetricKitHangs.subscribe(reports: reports))
    }
}

#if canImport(MetricKit) && os(iOS)
/// Receives MetricKit's daily diagnostic payloads (and, on iOS 15+, at once after a hang) and
/// keeps their hang diagnostics beside the watchdog's own hang files.
final class MetricKitHangs: NSObject, MXMetricManagerSubscriber, Sendable {
    let reports: HangReports

    init(reports: HangReports) {
        self.reports = reports
    }

    static func subscribe(reports: HangReports) -> AnyObject {
        let subscriber = MetricKitHangs(reports: reports)
        MXMetricManager.shared.add(subscriber)
        return subscriber
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for payload in payloads {
            for hang in payload.hangDiagnostics ?? [] {
                let seconds = hang.hangDuration.converted(to: .seconds).value
                HangReports.logger.error("MetricKit hang diagnostic: \(seconds, format: .fixed(precision: 2)) s")
                reports.recordMetricKit(json: hang.jsonRepresentation())
            }
        }
    }
}
#else
enum MetricKitHangs {
    static func subscribe(reports: HangReports) -> AnyObject? { nil }
}
#endif
