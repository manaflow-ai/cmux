public import CmuxNextCompat
import CmuxNextTrace
import CmuxNextWakeups
public import Foundation

extension HangReportService {
    /// The service of this app process: the store over `folder`, the real transport, classifier and
    /// dyld resolver, the bundle's version and build, this Mac's OS version and hardware class, and
    /// (when the builder's wire schema carries them) a ``MainThreadReportLedger`` over
    /// `mainThreadHistograms`.
    ///
    /// - Parameters:
    ///   - folder: This build's `HangReports` folder.
    ///   - endpoint: Where reports go.
    ///   - channel: `nightly`, `dev`, `rc` or `release`.
    ///   - personalTerms: This Mac's personal terms; read at the first name check, off the main thread.
    ///   - counts: The coarse counts of what is open now.
    ///   - stillAllowed: Whether sending is still allowed (``Environment/stillAllowed``).
    ///   - mainThreadHistograms: Reads the watchdog's cumulative main-turn and input-queueing counts.
    ///   - wireSchema: The schema reports are written in (``HangReport/WireSchema/written(serverAcceptsSchema3:)``).
    ///   - metricsDirectory: Where this app's metrics store keeps its launch files (the folder its `adoptFile` uses):
    ///     the earlier launches are read there.
    ///   - rings: Where the daemon, the holders and the hosts keep their black boxes.
    ///   - features: The features the app runs with (hash and overrides), read at each report and sent where the
    ///     wire schema carries them.
    ///   - blockingSites: Reads the blocking detector's main-thread sites and reset count
    ///     (`BlockingDetector.mainThreadRead`; empty where the detector is compiled out), counted into a
    ///     ``BlockingSiteLedger`` where the wire schema carries them.
    public static func forThisApp(folder: URL, endpoint: String, channel: String,
                                  personalTerms: @autoclosure @escaping @Sendable () -> [String],
                                  counts: @escaping @Sendable () async -> CoarseCounts, stillAllowed: @escaping @Sendable () -> Bool,
                                  mainThreadHistograms: @escaping @Sendable () -> MainThreadReportLedger.Histograms?,
                                  wireSchema: HangReport.WireSchema = .deployed,
                                  metricsDirectory: URL = HangReportFieldSources.appMetricsDirectory(bundleID: Bundle.main.bundleIdentifier),
                                  rings: HangReportFieldSources.RingFolders = .app(bundleID: Bundle.main.bundleIdentifier, flowsDirectory: nil),
                                  features: @escaping @Sendable () -> HangReport.FeatureState? = { nil },
                                  blockingSites: @escaping @Sendable () -> BlockingDetector.MainThreadRead = { .init() })
        -> HangReportService {
        let builder = HangReportBuilder(classifier: ImageClassifier(appBundlePath: Bundle.main.bundlePath, forbiddenTerms: personalTerms()),
                                        resolver: DyldImageResolver(), wireSchema: wireSchema)
        // Blocking sites are kept only when the schema the server accepts carries them.
        // Typed locals: the inline ternary over a closure literal crashed the type checker ("failed to produce
        // diagnostic") once this moved into this module.
        let resolve: HangReportCollector.Resolve = { builder.frames(addresses: $0) }
        var resolveBlocking: HangReportCollector.ResolveBlocking?
        if builder.wireSchema.carriesBlocking {
            resolveBlocking = { builder.frames(blocking: $0) }
        }
        // The field data and the black box only where the schema carries them: the rings of this app and of the
        // processes beside it, where each writes its own.
        var fieldData: HangReportFieldSources?
        var captureBlackBox: HangReportCollector.CaptureBlackBox?
        if builder.wireSchema.carriesFieldData {
            let sources = HangReportFieldSources(runtime: .shared, metricsDirectory: metricsDirectory, rings: rings)
            fieldData = sources
            captureBlackBox = { await sources.captureBlackBox() }
        }
        let collector = HangReportCollector(resolve: resolve, resolveBlocking: resolveBlocking, captureBlackBox: captureBlackBox,
                                            keepsThreadHangs: builder.wireSchema.carriesThreadHangs)
        let mainThread = builder.wireSchema.carriesMainThread ? MainThreadReportLedger(histograms: mainThreadHistograms) : nil
        let blocking = builder.wireSchema.carriesBlockingSites ? BlockingSiteLedger(sites: blockingSites) : nil
        let info = Bundle.main.infoDictionary ?? [:]
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return HangReportService(
            store: HangReportStore(directory: folder), transport: URLSessionHangReportTransport(endpoint: endpoint),
            builder: builder, scanner: PrivacyLeakScanner(forbiddenTerms: personalTerms()), identity: InstallIdentity(),
            collector: collector,
            environment: Environment(
                app: HangReport.App(version: info["CFBundleShortVersionString"] as? String ?? "0",
                                    build: info["CFBundleVersion"] as? String ?? "0", channel: channel),
                os: HangReport.OS(version: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
                hardware: .current(), counts: counts, stillAllowed: stillAllowed, mainThread: mainThread, fieldData: fieldData,
                features: features, blockingSites: blocking))
    }
}
