public import Foundation
import CmuxNextCompat
import CmuxNextTrace

/// What a crashed cmux Rust process (daemon, terminal host, holder, acpmux, agent host, app host, browser
/// host) leaves on disk for its macOS crash report (plans/cmux-next/chrome-parity/p09-observability.md, task 097): its black box
/// (`<role>-<pid>.blackbox.cmxtrace`, task 095) and its crash-key page (`<role>-<pid>.crashkeys`, task 098),
/// where the process writes them: the folders hang reports read the same rings from
/// (`HangReportFieldSources.RingFolders`: the app's trace folder, which the app hands the daemon and the daemon
/// its hosts, and the daemon's `CMUX_TRACE_FLOWS` folder when key-flow tracing is on), and each holder's
/// `<socket>.trace` folder beside its socket in `/tmp/cmux-hd-<uid>`.
///
/// Crashpad does the same from the dead process's memory: the crash keys and annotations of the crashed
/// process go into its minidump (components/crash/core/common/crash_key.h,
/// third_party/crashpad/crashpad/client/annotation.h). cmux reads them from the `MAP_SHARED` files the
/// process wrote with relaxed stores, which outlive it in the page cache.
///
/// A file belongs to the crash only when its header names the report's pid, the file's role, the crashed
/// image's `LC_UUID` and the process start the report gives (`procLaunch`, ``startTolerance``), so another
/// build, or a later process of this build given the same pid before the report is read, never lends its files.
/// The black box goes through the upload decoder (``CmuxNextTrace/TraceBlackBoxUpload``: catalog names and
/// numbers, at most 512 events, no key-timing, per-key PTY or flow record) and only with the hang-reports
/// opt-in, as on the app's own crash event (task 079). The crash keys are numbers and fixed state names and always go as tags.
///
/// ```swift
/// let artifacts = RustCrashArtifacts(directories: rings.directories, holderSockets: rings.holderSockets,
///                                    blackboxOptIn: { hangReportsOn() })
/// let extras = artifacts.extras(for: report)       // blocking file reads: the forwarder's queue
/// ```
public struct RustCrashArtifacts: Sendable {
    /// Whether a black box may leave the Mac now (the hang-reports opt-in).
    public typealias OptIn = @Sendable () -> Bool

    /// Folders whose `<role>-<pid>.*` files are read.
    public var directories: [URL]
    /// A folder of holder sockets: each `*.trace` folder in it holds one holder's files.
    public var holderSockets: URL?
    /// Read at each crash: the black box is attached only while it is true.
    public var blackboxOptIn: OptIn

    /// The roles whose files a Rust crash may have left.
    static let roles: [TraceRing.Role] = [.daemon, .terminalHost, .holder, .acpmux, .agentHost, .appHost, .browserHost]

    /// Artifacts read from `directories` and the `*.trace` folders in `holderSockets`.
    public init(directories: [URL], holderSockets: URL? = nil, blackboxOptIn: @escaping OptIn) {
        self.directories = directories
        self.holderSockets = holderSockets
        self.blackboxOptIn = blackboxOptIn
    }

    /// The most a file header's process start and the report's `procLaunch` differ for one process: both are the
    /// kernel's start time, the report's rounded to 100 µs.
    static let startTolerance: UInt64 = 10_000

    /// The black box and crash keys the crashed process of `report` left, its role and its build version; empty
    /// when the report names no pid, image UUID or process start, or no file matches them. Blocking file reads.
    public func extras(for report: SystemCrashReport) -> SystemCrashEvent.Extras {
        guard let pid = report.pid, pid > 0, let uuid = report.mainImageUUID.flatMap(Self.uuidBytes),
              let start = report.processStartUnixMicros, start != 0 else {
            return SystemCrashEvent.Extras()
        }
        let process = CrashedProcess(pid: UInt32(pid), uuid: uuid, startUnixMicros: start)
        let folders = folders()
        var extras = SystemCrashEvent.Extras()
        if case let (role, image)? = ring(of: process, in: folders) {
            extras.processRole = role.fileStem
            if blackboxOptIn() {
                extras.blackbox = TraceBlackBoxUpload().crashAttachmentText(TraceBlackBoxUpload.records(of: image),
                                                                            hangReportsOptIn: true)
            }
        }
        if case let (role, page)? = keyPage(of: process, in: folders) {
            extras.processRole = extras.processRole ?? role.fileStem
            extras.crashKeys = page.tags
            extras.buildVersion = page.buildVersion
        }
        return extras
    }

    /// The trace folders, then each holder's.
    private func folders() -> [URL] {
        let holders = holderSockets.map { sockets in
            ((try? FileManager.checked.contentsOfDirectory(at: sockets, includingPropertiesForKeys: nil,
                                                           options: [.skipsHiddenFiles])) ?? [])
                .filter { $0.pathExtension == "trace" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } ?? []
        return directories + holders
    }

    /// The crashed process as its files' headers name it.
    private struct CrashedProcess {
        let pid: UInt32
        /// The crashed image's `LC_UUID`.
        let uuid: [UInt8]
        /// The report's `procLaunch`, never 0.
        let startUnixMicros: UInt64

        /// Whether a header with these fields was written by this process: its pid, its image and a start within
        /// ``RustCrashArtifacts/startTolerance`` (a header that does not know its start, 0, is not).
        func wrote(pid: UInt32, uuid: [UInt8], startUnixMicros: UInt64) -> Bool {
            pid == self.pid && uuid == self.uuid && startUnixMicros != 0
                && max(startUnixMicros, self.startUnixMicros) - min(startUnixMicros, self.startUnixMicros)
                <= RustCrashArtifacts.startTolerance
        }
    }

    /// The first black box of `process` whose header names it and its file's role.
    private func ring(of process: CrashedProcess, in folders: [URL]) -> (TraceRing.Role, TraceRing.Image)? {
        for folder in folders {
            for role in Self.roles {
                let file = folder.appending(path: TraceRingFile.fileName(role: role, pid: process.pid))
                guard let data = try? Data(blockingContentsOf: file), let image = TraceRing.Image(bytes: [UInt8](data)),
                      image.header.roleCode == role.rawValue,
                      process.wrote(pid: image.header.pid, uuid: image.header.buildUUID,
                                    startUnixMicros: image.header.processStartUnixMicros) else { continue }
                return (role, image)
            }
        }
        return nil
    }

    /// The first crash-key page of `process` whose header names it and its file's role.
    private func keyPage(of process: CrashedProcess, in folders: [URL]) -> (TraceRing.Role, RustCrashKeyPage)? {
        for folder in folders {
            for role in Self.roles {
                let file = folder.appending(path: RustCrashKeyPage.fileName(role: role, pid: process.pid))
                guard let data = try? Data(blockingContentsOf: file),
                      let page = RustCrashKeyPage(bytes: [UInt8](data)), page.role == role.rawValue,
                      process.wrote(pid: page.pid, uuid: page.buildUUID, startUnixMicros: page.processStartUnixMicros)
                else { continue }
                return (role, page)
            }
        }
        return nil
    }

    /// The 16 bytes of a report's `8-4-4-4-12` UUID, in the order `LC_UUID` holds them; nil when it is not one.
    static func uuidBytes(_ text: String) -> [UInt8]? {
        let digits = text.utf8.filter { $0 != UInt8(ascii: "-") }
        guard digits.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        for index in stride(from: 0, to: 32, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index ..< index + 2], as: UTF8.self), radix: 16) else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }
}

/// A Rust process's crash-key page as task 098 writes it (cmux-trace `crash_keys.rs`; its `decode` reads the
/// same words): 512 little-endian 64-bit words. Header: 0 magic `CMXCKEYS`; 1 version 1 in the low 32 bits,
/// the role in bits 32-47; 2 pid; 3 process start (Unix microseconds); 4-5 the main image's `LC_UUID`; 8-11 the
/// build version. Keys: 12 request method, 13 terminal count, 14 holder link, 15 requests in flight past the
/// table, 16-31 the requests in flight (a method key each, 0 for a free entry). Only these keys become tags, as
/// decimal numbers or a fixed state name, and the build version only when it is version characters, so whatever
/// else a damaged or planted file holds never reaches a report.
struct RustCrashKeyPage: Equatable {
    /// The state of a process's link to its PTY holder (cmux-trace `crash_keys::HolderLink`).
    enum HolderLink: UInt64 {
        case never = 0
        case linked = 1
        case lost = 2
        case superseded = 3
        case failed = 4

        /// The state's tag value.
        var name: String {
            switch self {
            case .never: "never"
            case .linked: "linked"
            case .lost: "lost"
            case .superseded: "superseded"
            case .failed: "failed"
            }
        }
    }

    /// Word indexes of the layout (cmux-trace `crash_keys::word`).
    enum Word {
        static let magic = 0
        static let versionRole = 1
        static let pid = 2
        static let processStart = 3
        static let buildUUID = 4
        static let buildVersion = 8
        static let buildVersionWords = 4
        static let requestMethod = 12
        static let terminalCount = 13
        static let holderLink = 14
        static let untracked = 15
        static let inFlight = 16
        static let inFlightCapacity = 16
    }

    /// ASCII `CMXCKEYS` as a little-endian word (cmux-trace `crash_keys::MAGIC`).
    static let magic: UInt64 = 0x5359_454B_4358_4D43
    /// The page format version this build reads (cmux-trace `crash_keys::VERSION`).
    static let version: UInt32 = 1
    /// The page's size in bytes (cmux-trace `crash_keys::PAGE_BYTES`).
    static let byteCount = 512 * 8

    /// The page's file name for `role` in process `pid`, beside its black box (cmux-trace `page_file_name`).
    static func fileName(role: TraceRing.Role, pid: UInt32) -> String {
        "\(role.fileStem)-\(pid).crashkeys"
    }

    let pid: UInt32
    let role: UInt16
    /// The process start in Unix microseconds; 0 when the writer did not know it.
    let processStartUnixMicros: UInt64
    let buildUUID: [UInt8]
    /// The writer's build version (`0.1.0`); nil when the words are empty or hold anything but version characters.
    let buildVersion: String?
    /// The method key of the request that started last (FNV-1a 64 of its wire name); 0 before the first.
    let requestMethod: UInt64
    let terminalCount: UInt64
    /// The holder link word as written: a ``HolderLink`` raw value, or a code a newer writer added.
    let holderLink: UInt64
    /// The requests running when the process died: the named ones and those past the full table.
    let requestsInFlight: UInt64

    /// The page in `bytes`; nil when it is shorter than a page, has no magic (not a page, or one whose file was
    /// being made) or is another version.
    init?(bytes: [UInt8]) {
        guard bytes.count >= Self.byteCount else { return nil }
        func word(_ index: Int) -> UInt64 {
            (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[index * 8 + $1]) << (8 * UInt64($1)) }
        }
        let versionRole = word(Word.versionRole)
        guard word(Word.magic) == Self.magic, UInt32(truncatingIfNeeded: versionRole) == Self.version else { return nil }
        role = UInt16(truncatingIfNeeded: versionRole >> 32)
        pid = UInt32(truncatingIfNeeded: word(Word.pid))
        processStartUnixMicros = word(Word.processStart)
        buildUUID = Array(bytes[Word.buildUUID * 8 ..< (Word.buildUUID + 2) * 8])
        buildVersion = Self.version(bytes[Word.buildVersion * 8 ..< (Word.buildVersion + Word.buildVersionWords) * 8])
        requestMethod = word(Word.requestMethod)
        terminalCount = word(Word.terminalCount)
        holderLink = word(Word.holderLink)
        var named: UInt64 = 0
        for index in Word.inFlight ..< Word.inFlight + Word.inFlightCapacity where word(index) != 0 { named += 1 }
        requestsInFlight = named &+ word(Word.untracked)
    }

    /// NUL-padded ASCII of letters, digits and `.+-_` as a string; nil for anything else.
    private static func version(_ bytes: ArraySlice<UInt8>) -> String? {
        let text = bytes.prefix { $0 != 0 }
        let isVersionByte = { (byte: UInt8) -> Bool in
            (0x30 ... 0x39).contains(byte) || (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte)
                || [UInt8(ascii: "."), UInt8(ascii: "+"), UInt8(ascii: "-"), UInt8(ascii: "_")].contains(byte)
        }
        guard !text.isEmpty, text.allSatisfy(isVersionByte), bytes.dropFirst(text.count).allSatisfy({ $0 == 0 }) else {
            return nil
        }
        return String(decoding: text, as: UTF8.self)
    }

    /// The keys as tags (`crash_key.<name>`): the request method once one ran, the counts, and the holder link
    /// by name (its decimal code when this build does not know it).
    var tags: [String: String] {
        var tags = [
            "crash_key.terminal_count": String(terminalCount),
            "crash_key.requests_in_flight": String(requestsInFlight),
            "crash_key.holder_link": HolderLink(rawValue: holderLink)?.name ?? String(holderLink),
        ]
        if requestMethod != 0 { tags["crash_key.request_method"] = String(requestMethod) }
        return tags
    }
}
