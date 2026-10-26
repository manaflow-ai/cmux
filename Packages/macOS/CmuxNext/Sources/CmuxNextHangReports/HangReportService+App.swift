import CmuxNextCompat
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
    public static func forThisApp(folder: URL, endpoint: String, channel: String,
                                  personalTerms: @autoclosure @escaping @Sendable () -> [String],
                                  counts: @escaping @Sendable () async -> CoarseCounts, stillAllowed: @escaping @Sendable () -> Bool,
                                  mainThreadHistograms: @escaping @Sendable () -> MainThreadReportLedger.Histograms?) -> HangReportService {
        let builder = HangReportBuilder(classifier: ImageClassifier(appBundlePath: Bundle.main.bundlePath, forbiddenTerms: personalTerms()),
                                        resolver: DyldImageResolver())
        // Blocking sites are kept only when the schema the server accepts carries them. A ternary gives its
        // closure branch no contextual type, so the closure says `@Sendable` itself.
        let resolveBlocking: HangReportCollector.ResolveBlocking? = builder.wireSchema.carriesBlocking
            ? { @Sendable (stack: [BlockingFrame]) -> [HangReportFrame] in builder.frames(blocking: stack) }
            : nil
        let collector = HangReportCollector(resolve: { builder.frames(addresses: $0) }, resolveBlocking: resolveBlocking)
        let mainThread = builder.wireSchema.carriesMainThread ? MainThreadReportLedger(histograms: mainThreadHistograms) : nil
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
                hardware: .current(), counts: counts, stillAllowed: stillAllowed, mainThread: mainThread))
    }
}
