public import Foundation

/// Gathers what a ``HangReport`` needs from this process (the images its stacks name, through
/// ``ImageResolving``, and which bare names are Apple's on disk) and asks Rust's rules
/// (``HangReportRules``) to build, fit, scan and encode it: the allow-list of hang-reports-DESIGN.md
/// section 4 and the frame rules of section 3 live in cmux-tui/crates/cmux-hang-report.
///
/// ```swift
/// let builder = HangReportBuilder(classifier: classifier, resolver: DyldImageResolver())
/// let composed = builder.compose(context: context, watchdog: aggregate, metricKit: deliveries)
/// ```
public nonisolated struct HangReportBuilder: Sendable {
    /// The envelope of one report: who, when and what was open.
    public struct Context: Sendable, Equatable, Encodable {
        /// A random id per report.
        public var reportId: String
        /// ``InstallIdentity``'s id.
        public var installId: String
        /// The UTC day (`yyyy-MM-dd`).
        public var day: String
        /// The app that wrote the report.
        public var app: HangReport.App
        /// The macOS version.
        public var os: HangReport.OS
        /// The kind of Mac.
        public var hardware: HardwareClass
        /// Rounded counts of what was open.
        public var counts: CoarseCounts

        /// Makes the value from its parts.
        public init(reportId: String, installId: String, day: String, app: HangReport.App, os: HangReport.OS,
                    hardware: HardwareClass, counts: CoarseCounts) {
            self.reportId = reportId
            self.installId = installId
            self.day = day
            self.app = app
            self.os = os
            self.hardware = hardware
            self.counts = counts
        }
    }

    /// One composed report: the body to queue and its readable copy, or why there is none.
    public struct Composed: Sendable, Equatable {
        /// What the rules decided.
        public enum Status: Sendable, Equatable {
            /// Nothing worth sending.
            case empty
            /// Over the body cap even fitted.
            case tooLarge
            /// The leak scan found something: never sent.
            case refused([PrivacyLeakScanner.Finding])
            /// `body` may be queued.
            case ok
        }

        /// What the rules decided.
        public var status: Status
        /// The wire body (sorted keys), set when ``status`` is ``Status/ok``.
        public var body: Data?
        /// The readable copy of ``body`` (View Hang Report).
        public var readable: Data?
    }

    /// The facts the frame rules read (the app bundle, personal terms, Apple images on disk).
    public let classifier: ImageClassifier
    /// Finds the loaded image of an address or UUID.
    public let resolver: any ImageResolving

    /// Makes the value from its parts.
    public init(classifier: ImageClassifier, resolver: any ImageResolving) {
        self.classifier = classifier
        self.resolver = resolver
    }

    /// The report of `watchdog`'s findings and the MetricKit deliveries since the last report,
    /// fitted, scanned and encoded; nil when the rules do not answer (nothing is sent).
    public func compose(context: Context, watchdog: StallAggregate, metricKit: [MetricKitInput]) -> Composed? {
        guard let reply = HangReportRules.call("compose", request(context, watchdog, metricKit), as: HangReportRules.Composed.self) else {
            return nil
        }
        let status: Composed.Status = switch reply.status {
        case .empty: .empty
        case .tooLarge: .tooLarge
        case .refused: .refused(reply.findings)
        case .ok: .ok
        }
        return Composed(status: status, body: reply.body.map { Data($0.utf8) }, readable: reply.readable.map { Data($0.utf8) })
    }

    /// The readable copy of what would be sent now, nil when the leak scan refuses it.
    public func preview(context: Context, watchdog: StallAggregate, metricKit: [MetricKitInput]) -> Data? {
        HangReportRules.call("preview", request(context, watchdog, metricKit), as: HangReportRules.Readable.self)?
            .readable.map { Data($0.utf8) }
    }

    /// Frames of a watchdog sample (return addresses, innermost first); every frame is
    /// ``HangReportFrame/other`` when the rules do not answer.
    public func frames(addresses: [UInt]) -> [HangReportFrame] {
        let addresses = addresses.prefix(HangSample.maxFrames).map { address in
            HangReportRules.Frames.Address(address: UInt64(address),
                                           image: resolver.image(containing: UInt64(address)).map(HangReportRules.Image.init))
        }
        let request = HangReportRules.Frames(addresses: addresses, appBundlePath: classifier.appBundlePath,
                                             forbiddenTerms: classifier.terms())
        return HangReportRules.call("frames", request, as: HangReportRules.FramesReply.self)?.frames
            ?? Array(repeating: .other, count: addresses.count)
    }

    /// The compose request: the deliveries' stacks name images by UUID and name; this process
    /// answers which of those UUIDs are loaded and which bare names are Apple's.
    private func request(_ context: Context, _ watchdog: StallAggregate, _ metricKit: [MetricKitInput]) -> HangReportRules.Compose {
        let deliveries = metricKit.map(HangReportRules.MetricKit.init)
        let trees = deliveries.flatMap { $0.hangs.map(\.callStackTree) + $0.cpuExceptions.map(\.callStackTree) }
        let refs = trees.isEmpty ? HangReportRules.StackRefs()
            : HangReportRules.call("stack_refs", HangReportRules.Trees(trees: trees), as: HangReportRules.StackRefs.self)
            ?? HangReportRules.StackRefs()
        return HangReportRules.Compose(
            context: context, watchdog: watchdog, metricKit: deliveries, appBundlePath: classifier.appBundlePath,
            forbiddenTerms: classifier.terms(), systemImages: refs.names.filter(classifier.systemImageExists),
            loadedImages: refs.uuids.compactMap { resolver.image(uuid: $0) }.map(HangReportRules.Image.init))
    }
}
