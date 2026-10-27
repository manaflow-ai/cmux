import CmuxNextDesign
import CmuxNextMetrics
import CmuxNextSignposts
import CmuxNextTrace
import Foundation
import os
import WebKit

/// One field-data report of a cmux page: what ``WebTheme/bootstrapScript`` posts to
/// ``WebTheme/perfHandlerName`` (webviews/src/protocol/perfReport.ts), `{v: 1, inp, loaf, errors}`.
/// Only the page's own top document may report, and a report holds numbers only: one with another key
/// (a URL, a page name) is refused, so nothing the page says becomes a histogram name.
///
/// ```swift
/// PagePerfReport(message, from: .settings)?.interactions // [240, 32]
/// ```
nonisolated struct PagePerfReport: Equatable, Sendable {
    /// The most samples one list may carry: twice the page's ``WebTheme/perfReportCapacity``.
    static let maximumSamples = 2 * WebTheme.perfReportCapacity
    /// The longest duration a report may carry, in ms (the ms histograms' top bucket, one hour).
    static let maximumMilliseconds = 3_600_000.0
    /// The most script errors one report may count.
    static let maximumErrors: Int64 = 1_000_000

    /// Each interaction's longest Event Timing entry, in ms.
    let interactions: [Int64]
    /// Each long animation frame (or long task), in ms.
    let longFrames: [Int64]
    /// Script errors and unhandled rejections since the page's last report.
    let errors: Int64

    init(interactions: [Int64], longFrames: [Int64], errors: Int64) {
        self.interactions = interactions
        self.longFrames = longFrames
        self.errors = errors
    }

    /// The report `message` carries; nil when its sender is not `page`'s top document
    /// (``PageHostTrust``) or its body is not a report.
    @MainActor
    init?(_ message: PageHostMessage, from page: PageDescriptor) {
        guard PageHostTrust.isTrusted(message, page: page) else { return nil }
        self.init(body: message.body)
    }

    /// The report `body` is; nil for any other shape, version, key or out-of-range number.
    init?(body: Any) {
        guard let object = body as? [String: Any], Set(object.keys).isSubset(of: ["v", "inp", "loaf", "errors"]),
              (object["v"] as? NSNumber)?.intValue == 1,
              let interactions = Self.durations(object["inp"]), let longFrames = Self.durations(object["loaf"]),
              let errors = object["errors"] as? NSNumber,
              errors.doubleValue >= 0, errors.doubleValue <= Double(Self.maximumErrors),
              errors.doubleValue == errors.doubleValue.rounded() else { return nil }
        self.init(interactions: interactions, longFrames: longFrames, errors: errors.int64Value)
    }

    private static func durations(_ value: Any?) -> [Int64]? {
        guard let list = value as? [Any], list.count <= maximumSamples else { return nil }
        var out: [Int64] = []
        out.reserveCapacity(list.count)
        for item in list {
            guard let number = item as? NSNumber, number.doubleValue.isFinite,
                  number.doubleValue >= 0, number.doubleValue <= maximumMilliseconds else { return nil }
            out.append(Int64(number.doubleValue.rounded()))
        }
        return out
    }
}

extension PagePerfReport {
    /// Adds the WebKit handler of the reports to `controller`; `receive` gets each one in the turn WebKit
    /// delivers it, with the sender's frame facts.
    @MainActor
    static func install(in controller: WKUserContentController, receive: @escaping @MainActor (PageHostMessage) -> Void) {
        controller.add(PagePerfReceiver(receive: receive), contentWorld: .page, name: WebTheme.perfHandlerName)
    }
}

/// WebKit delivers script messages on the main thread: the report is read in the message's own turn.
private final class PagePerfReceiver: NSObject, WKScriptMessageHandler {
    let receive: @MainActor (PageHostMessage) -> Void

    init(receive: @escaping @MainActor (PageHostMessage) -> Void) {
        self.receive = receive
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        receive(PageHostMessage(frameURL: message.frameInfo.request.url, isMainFrame: message.frameInfo.isMainFrame,
                                body: message.body))
    }
}

extension HistogramID.Page {
    /// The histogram page of the page with descriptor id `pageID` shown as `surface`, from the static
    /// list: a page shown as the Home surface is ``home`` (Home's web view is the channels page, in the
    /// dock and as a tab), and a page the list does not name is ``other``.
    nonisolated init(pageID: String, surface: SurfaceKind? = nil) {
        if surface == .home {
            self = .home
            return
        }
        switch pageID {
        case "cmux.history": self = .history
        case "cmux.apps": self = .apps
        case "cmux.settings": self = .settings
        case "cmux.cloud": self = .cloud
        case "cmux.agent": self = .agent
        case "cmux.keybindings": self = .keybindings
        case "cmux.diff": self = .diff
        case "cmux.markdown": self = .markdown
        case "cmux.passwords": self = .passwords
        case "cmux.editor": self = .editor
        case "cmux.changelog": self = .changelog
        case "cmux.icon-picker": self = .iconPicker
        case "cmux.chief-inspector": self = .chiefInspector
        case "cmux.debug-settings": self = .debugSettings
        case "cmux.home-channels": self = .homeChannels
        default: self = .other
        }
    }

    /// The page's index in the list: the `arg0` of its ``SignpostName/webviewINP`` and
    /// ``SignpostName/webviewLoAF`` ring instants.
    nonisolated var traceIndex: UInt64 {
        UInt64(Self.allCases.firstIndex(of: self) ?? 0)
    }
}

/// Records one page view's reports, each in the turn it arrives: each interaction into
/// `webview.inp.<page>`, each long frame into `webview.loaf_ms.<page>`, with a ring instant each (the
/// duration in us), and a report's non-zero script error count as one `webview.js_errors.<page>` sample,
/// so the histogram's sum is the page's errors. Nothing waits for the document to end: a page closed
/// or still open at quit has reported its errors already (the bootstrap reports an error at once).
nonisolated struct PagePerfRecorder: Sendable {
    /// Where the samples and instants go (tests pass a recorder on their own runtime).
    let metrics: CmuxNextMetrics.Metrics

    init(metrics: CmuxNextMetrics.Metrics = CmuxNextMetrics.Metrics()) {
        self.metrics = metrics
    }

    /// Records `report`, which the page's top document sent as `page`.
    func record(_ report: PagePerfReport, page: HistogramID.Page) {
        let index = page.traceIndex
        for milliseconds in report.interactions {
            metrics.record(.webviewINP(page), milliseconds)
            metrics.runtime.event(.webviewINP, arg0: index, arg1: UInt64(milliseconds) * 1_000)
        }
        for milliseconds in report.longFrames {
            metrics.record(.webviewLoAF(page), milliseconds)
            metrics.runtime.event(.webviewLoAF, arg0: index, arg1: UInt64(milliseconds) * 1_000)
        }
        if report.errors > 0 {
            metrics.record(.webviewJSErrors(page), report.errors)
        }
    }
}

extension PageWebView {
    /// A ``WebTheme/perfHandlerName`` message from either engine: recorded when it is a report of this
    /// page's top document.
    func receivePerfReport(_ message: PageHostMessage) {
        guard let report = PagePerfReport(message, from: descriptor) else {
            logger.error("page \(self.descriptor.id, privacy: .public) perf report refused")
            return
        }
        perf.record(report, page: HistogramID.Page(pageID: descriptor.id, surface: themeSurface))
    }
}
