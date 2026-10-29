public import Foundation

extension HangReportService {
    /// The values a report's envelope needs from the app.
    public struct Environment: Sendable {
        /// The app that wrote the report.
        public var app: HangReport.App
        /// The macOS version.
        public var os: HangReport.OS
        /// The kind of Mac.
        public var hardware: HardwareClass
        /// The coarse counts of what is open now (the app reads them on the main actor).
        public var counts: @Sendable () async -> CoarseCounts
        /// The clock (tests pass a fixed one).
        public var now: @Sendable () -> Date
        /// Makes each report's random id.
        public var makeReportID: @Sendable () -> String
        /// Whether sending is still allowed, read before each report, delivery and send (the app
        /// passes the managed `DisableTelemetry`, so a profile installed while cmux runs stops the
        /// next send and drops what was recorded).
        public var stillAllowed: @Sendable () -> Bool
        /// The input latency field report (``HangReportInputLatencySource``); nil (the default)
        /// until the app wires it. Used only when the builder's wire schema
        /// carries input latency.
        public var inputLatency: (any HangReportInputLatencySource)?
        /// The active time and the main-turn and input-queueing histograms
        /// (``MainThreadReportLedger``, fed by ``MainThreadActivityFeed``); nil (the default) where the
        /// app has none. Used only when the builder's wire schema carries them.
        public var mainThread: MainThreadReportLedger?
        /// The metrics store, earlier launches and black-box rings (``HangReportFieldSources``); nil (the
        /// default) where the app has none. Used only when the builder's wire schema carries field data.
        public var fieldData: HangReportFieldSources?
        /// The features the app runs with now (hash and overrides), read as each report is built so a live
        /// toggle changed since launch is named; nil (the default) where the app passes none. Used only when
        /// the builder's wire schema carries them.
        public var features: @Sendable () -> HangReport.FeatureState?
        /// The main thread's blocking site counts (``BlockingSiteLedger``, over the detector's sites); nil (the
        /// default) where the app has none. Used only when the builder's wire schema carries them.
        public var blockingSites: BlockingSiteLedger?

        /// Makes the value from its parts.
        public init(app: HangReport.App, os: HangReport.OS, hardware: HardwareClass,
                    counts: @escaping @Sendable () async -> CoarseCounts, now: @escaping @Sendable () -> Date = Date.init,
                    makeReportID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
                    stillAllowed: @escaping @Sendable () -> Bool = { true },
                    inputLatency: (any HangReportInputLatencySource)? = nil, mainThread: MainThreadReportLedger? = nil,
                    fieldData: HangReportFieldSources? = nil,
                    features: @escaping @Sendable () -> HangReport.FeatureState? = { nil },
                    blockingSites: BlockingSiteLedger? = nil) {
            self.app = app
            self.os = os
            self.hardware = hardware
            self.counts = counts
            self.now = now
            self.makeReportID = makeReportID
            self.stillAllowed = stillAllowed
            self.inputLatency = inputLatency
            self.mainThread = mainThread
            self.fieldData = fieldData
            self.features = features
            self.blockingSites = blockingSites
        }
    }
}
