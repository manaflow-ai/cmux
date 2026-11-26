import Foundation
#if canImport(MetricKit) && os(iOS)
import MetricKit
#endif

/// The app's hang watch, started once at launch (`CmuxMobileApp.init`): the main-thread
/// watchdog writing hang files through ``HangReports``, and a MetricKit subscriber collecting
/// `MXHangDiagnostic` payloads into the same directory.
public enum HangWatch {
    @MainActor private static var started: (watchdog: MainThreadHangWatchdog, reports: HangReports, metrics: AnyObject?)?

    /// The last run's hard hang, read once at ``start()`` (nil: none).
    @MainActor public private(set) static var priorHang: HangRestoreMarker?

    /// The running watchdog (nil before ``start()``).
    @MainActor public static var watchdog: MainThreadHangWatchdog? { started?.watchdog }

    @MainActor
    public static func start(reports: HangReports = HangReports()) {
        guard started == nil else { return }
        // A hard hang in the last run: reported once, and its screen handed to the launch restore.
        priorHang = HangRestoreMarker.handlePriorHang()
        let watchdog = MainThreadHangWatchdog()
        watchdog.onHang = { hang in reports.record(hang) }
        // Before iOS's watchdog kills a stuck app (about 10 s and more): where the user was.
        // Written from the watchdog thread; nothing here stops the app (cmux#50992).
        watchdog.onHardHang = { hang in
            let now = MainThreadHangWatchdog.now()
            let started = Date().addingTimeInterval(-Double(now > hang.startUptimeNanos ? now - hang.startUptimeNanos : 0) / 1e9)
            let ms = Int(hang.duration.components.seconds * 1_000 + hang.duration.components.attoseconds / 1_000_000_000_000_000)
            HangRestoreMarker(hangStarted: started, durationMilliseconds: ms, location: LastOpenMemory.standard.load()).write()
        }
        // The hang ended and the app lived: the marker would report a hang this launch survived.
        watchdog.onHardHangEnded = { _ in HangRestoreMarker.clear() }
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
