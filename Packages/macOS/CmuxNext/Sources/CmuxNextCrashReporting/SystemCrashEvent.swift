import Foundation
public import Sentry

/// A Sentry event for a helper process crash that macOS recorded (the
/// cmux-tui daemon and its terminal, app and browser hosts, the holder,
/// acpmux, the Chromium helpers), or that Crashpad dumped (a helper of the
/// Chromium Host, ``ChromiumMinidumpReport/systemReport``). Frames carry
/// instruction addresses and the debug images their UUIDs, so Sentry symbolicates them from the debug
/// files the nightly uploads, as for the app's own crashes. A Rust process's
/// crash also carries what it left on disk (``Extras``): its crash keys as
/// tags and its black box as `blackbox.txt`, as Crashpad attaches a dead
/// process's crash keys and annotations to its minidump.
public nonisolated struct SystemCrashEvent: Sendable {
    /// Where the report came from: the event's `crash_source` tag.
    public enum Source: String, Sendable {
        /// macOS's crash reporter (an `.ips` file, ``SystemCrashForwarder``).
        case macOSCrashReport = "macos_crash_report"
        /// A Crashpad dump of a Chromium helper (``ChromiumMinidumpCollector``).
        case crashpad
    }

    /// What the crashed process left beside the report (``RustCrashArtifacts``) and where it ran from.
    public struct Extras: Sendable, Equatable {
        /// Where the binary ran from (tag `process_origin`).
        public var origin: SystemCrashReport.HelperOrigin?
        /// Whether the crashed image is one of the binaries this app runs now (tag `process_build`: `this`, or
        /// `other` for an earlier build of this app whose host-exe copy kept running after an update); nil when not
        /// checked (a bundle binary is always this build's).
        public var fromThisBuild: Bool?
        /// The Sentry release of the build whose binary crashed (`cmux-next@<version>+<build>`); nil: the SDK's,
        /// this app's own.
        public var release: String?
        /// The build version the crashed process wrote in its crash-key page (tag `process_build_version`).
        public var buildVersion: String?
        /// The process kind its black box or crash-key page names (`daemon`, `terminal-host`, `holder`,
        /// `acpmux`; tag `process_role`).
        public var processRole: String?
        /// `blackbox.txt`: the newest black-box events with no key-timing, per-key PTY or flow record
        /// (``CmuxNextTrace/TraceBlackBoxUpload``); nil without the hang-reports opt-in or a ring.
        public var blackbox: String?
        /// The crash keys as tags (`crash_key.<name>`: decimal numbers and fixed state names only).
        public var crashKeys: [String: String]

        /// Extras from their parts.
        public init(origin: SystemCrashReport.HelperOrigin? = nil, fromThisBuild: Bool? = nil,
                    release: String? = nil, buildVersion: String? = nil,
                    processRole: String? = nil, blackbox: String? = nil, crashKeys: [String: String] = [:]) {
            self.origin = origin
            self.fromThisBuild = fromThisBuild
            self.release = release
            self.buildVersion = buildVersion
            self.processRole = processRole
            self.blackbox = blackbox
            self.crashKeys = crashKeys
        }
    }

    /// The black box's attachment name, as on the app's own crash event (``CrashReporter/blackboxAttachment(_:hangReportsOptIn:)``).
    public static let blackboxFileName = "blackbox.txt"

    public let report: SystemCrashReport
    public let source: Source
    public let extras: Extras

    public init(report: SystemCrashReport, source: Source = .macOSCrashReport, extras: Extras = Extras()) {
        self.report = report
        self.source = source
        self.extras = extras
    }

    /// The event's attachments: `blackbox.txt` when ``Extras/blackbox`` has one.
    public func attachments() -> [Attachment] {
        guard let blackbox = extras.blackbox, !blackbox.isEmpty else { return [] }
        return [Attachment(data: Data(blackbox.utf8), filename: Self.blackboxFileName, contentType: "text/plain")]
    }

    public func event() -> Event {
        let event = Event(level: .fatal)
        event.platform = "cocoa"
        // The SDK puts its own release only on an event that has none (SentryClient prepareEvent).
        if let release = extras.release { event.releaseName = release }
        var exceptions: [Exception] = []
        if !report.exceptionFrames.isEmpty {
            // The Objective-C throw stack goes first: Sentry lists the
            // oldest exception first and groups by the last one.
            let thrown = Exception(value: "uncaught exception", type: "NSException")
            thrown.mechanism = mechanism(type: "nsexception")
            thrown.stacktrace = stacktrace(report.exceptionFrames)
            exceptions.append(thrown)
        }
        let crash = Exception(value: [report.signal, report.termination].compactMap { $0 }.joined(separator: ", "),
                              type: report.exceptionType)
        crash.mechanism = mechanism(type: "mach")
        crash.stacktrace = stacktrace(report.frames)
        exceptions.append(crash)
        event.exceptions = exceptions
        event.debugMeta = report.images.filter { !$0.uuid.isEmpty }.map { image in
            let meta = DebugMeta()
            meta.type = "macho"
            meta.debugID = image.uuid
            meta.imageAddress = Self.hex(image.base)
            meta.imageSize = NSNumber(value: image.size)
            meta.codeFile = image.name
            return meta
        }
        var tags = extras.crashKeys
        tags["process"] = report.processName
        tags["crash_source"] = source.rawValue
        // The same tag as a Chromium helper's exit event (``HelperExitEvent``): one search finds both.
        if let pid = report.pid { tags["pid"] = String(pid) }
        if let origin = extras.origin { tags["process_origin"] = origin.rawValue }
        if let role = extras.processRole { tags["process_role"] = role }
        if let fromThisBuild = extras.fromThisBuild { tags["process_build"] = fromThisBuild ? "this" : "other" }
        if let version = extras.buildVersion { tags["process_build_version"] = version }
        event.tags = tags
        if let incident = report.incident {
            event.extra = ["incident": incident]
            // One id per macOS incident: a report forwarded again (a lost forwarder state) is the same event.
            if let id = UUID(uuidString: incident) { event.eventId = SentryId(uuid: id) }
        }
        return event
    }

    private func mechanism(type: String) -> Mechanism {
        let mechanism = Mechanism(type: type)
        mechanism.handled = false
        return mechanism
    }

    /// Sentry frames run outermost first; the report lists innermost first.
    private func stacktrace(_ frames: [SystemCrashReport.Frame]) -> SentryStacktrace {
        let sentryFrames: [Frame] = frames.reversed().compactMap { frame in
            guard report.images.indices.contains(frame.imageIndex) else { return nil }
            let image = report.images[frame.imageIndex]
            let out = Frame()
            out.instructionAddress = Self.hex(image.base &+ frame.imageOffset)
            out.imageAddress = Self.hex(image.base)
            out.package = image.name
            out.function = frame.symbol
            return out
        }
        return SentryStacktrace(frames: sentryFrames, registers: [:])
    }

    static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }
}
