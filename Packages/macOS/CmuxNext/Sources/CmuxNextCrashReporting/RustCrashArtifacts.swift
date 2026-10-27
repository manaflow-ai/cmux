public import Foundation
import CmuxNextCompat
import CmuxNextTrace
import CmuxNextWakeups

/// What a crashed cmux Rust process (daemon, terminal host, holder, acpmux) leaves on disk for its macOS
/// crash report (plans/cmux-next/chrome-parity/p09-observability.md, task 097): its black box
/// (`<role>-<pid>.blackbox.cmxtrace`, task 095) and its crash-key page (`<role>-<pid>.crashkeys`, task 098),
/// where the process writes them: the app's trace folder, which the app hands the daemon and the daemon its
/// hosts, and each holder's `<socket>.trace` folder beside its socket in `/tmp/cmux-hd-<uid>`.
///
/// Crashpad does the same from the dead process's memory: the crash keys and annotations of the crashed
/// process go into its minidump (components/crash/core/common/crash_key.h,
/// third_party/crashpad/crashpad/client/annotation.h). cmux reads them from the `MAP_SHARED` files the
/// process wrote with relaxed stores, which outlive it in the page cache.
///
/// A file belongs to the crash only when its header names the report's pid, the file's role and the crashed
/// image's `LC_UUID`, so a reused pid or another build never lends its ring. The black box goes through the
/// upload decoder (``CmuxNextTrace/TraceBlackBoxUpload``: catalog names and numbers, at most 512 events, no
/// key-timing, per-key PTY or flow record) and only with the hang-reports opt-in, as on the app's own crash
/// event (task 079). The crash keys are numbers and always go as tags.
///
/// ```swift
/// let artifacts = RustCrashArtifacts.app(bundleID: Bundle.main.bundleIdentifier, blackboxOptIn: { hangReportsOn() })
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
    static let roles: [TraceRing.Role] = [.daemon, .terminalHost, .holder, .acpmux]

    /// Artifacts read from `directories` and the `*.trace` folders in `holderSockets`.
    public init(directories: [URL], holderSockets: URL? = nil, blackboxOptIn: @escaping OptIn) {
        self.directories = directories
        self.holderSockets = holderSockets
        self.blackboxOptIn = blackboxOptIn
    }

    /// The folders of the app with bundle id `bundleID`: its trace folder
    /// (``CmuxNextWakeups/TraceBlackBoxFileSteps/appDirectory(bundleID:home:)``) and this user's holder socket
    /// folder (`/tmp/cmux-hd-<uid>`, cmux-tui-core `holder_runtime::service::socket_path`).
    public static func app(bundleID: String?, uid: UInt32 = getuid(),
                           home: URL = FileManager.default.homeDirectoryForCurrentUser,
                           blackboxOptIn: @escaping OptIn) -> RustCrashArtifacts {
        RustCrashArtifacts(directories: [TraceBlackBoxFileSteps.appDirectory(bundleID: bundleID, home: home)],
                           holderSockets: URL(filePath: "/tmp/cmux-hd-\(uid)", directoryHint: .isDirectory),
                           blackboxOptIn: blackboxOptIn)
    }

    /// The black box and crash keys the crashed process of `report` left, and its role; empty when the report
    /// names no pid or image UUID, or no file matches both. Blocking file reads.
    public func extras(for report: SystemCrashReport) -> SystemCrashEvent.Extras {
        guard let pid = report.pid, pid > 0, let uuid = report.mainImageUUID.flatMap(Self.uuidBytes) else {
            return SystemCrashEvent.Extras()
        }
        let process = UInt32(pid)
        let folders = folders()
        var extras = SystemCrashEvent.Extras()
        if case let (role, image)? = ring(of: process, uuid: uuid, in: folders) {
            extras.processRole = role.fileStem
            if blackboxOptIn() {
                extras.blackbox = TraceBlackBoxUpload().crashAttachmentText(TraceBlackBoxUpload.records(of: image),
                                                                            hangReportsOptIn: true)
            }
        }
        if case let (role, page)? = keyPage(of: process, uuid: uuid, in: folders) {
            extras.processRole = extras.processRole ?? role.fileStem
            extras.crashKeys = page.tags
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

    /// The first black box of process `pid` whose header names that pid, its file's role and `uuid`.
    private func ring(of pid: UInt32, uuid: [UInt8], in folders: [URL]) -> (TraceRing.Role, TraceRing.Image)? {
        for folder in folders {
            for role in Self.roles {
                let file = folder.appending(path: TraceRingFile.fileName(role: role, pid: pid))
                guard let data = try? Data(blockingContentsOf: file), let image = TraceRing.Image(bytes: [UInt8](data)),
                      image.header.pid == pid, image.header.roleCode == role.rawValue,
                      image.header.buildUUID == uuid else { continue }
                return (role, image)
            }
        }
        return nil
    }

    /// The first crash-key page of process `pid` whose header names that pid, its file's role and `uuid`.
    private func keyPage(of pid: UInt32, uuid: [UInt8], in folders: [URL]) -> (TraceRing.Role, RustCrashKeyPage)? {
        for folder in folders {
            for role in Self.roles {
                let file = folder.appending(path: RustCrashKeyPage.fileName(role: role, pid: pid))
                guard let data = try? Data(blockingContentsOf: file),
                      let page = RustCrashKeyPage(bytes: [UInt8](data)),
                      page.pid == pid, page.role == role.rawValue, page.buildUUID == uuid else { continue }
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

/// A Rust process's crash-key page as task 098 writes it (cmux-trace `crash_keys.rs`), in the app page's
/// layout (`CrashKeyPage`, task 078): 512 little-endian 64-bit words. Words 0-7 are the header: 0 magic
/// `CMXKEYS1`; 1 version 1, header words `<< 16`, page words `<< 32`; 2 pid, role `<< 32`; 3-4 the main image's
/// `LC_UUID`; 5 process start (Unix microseconds); 6 the page's start (uptime ns); 7 reserved. The slots share
/// the app's word numbers where they mean the same (``Slot``). Only the slots below become tags, as decimal
/// numbers, so whatever else a damaged or planted file holds never reaches a report.
struct RustCrashKeyPage: Equatable {
    /// A slot a Rust process sets, at its word in the page.
    enum Slot: Int, CaseIterable {
        /// The request the process runs, as `stable_key` of its method name (cmux-panic-log `Key::ActionId`);
        /// the app's running action is the same word (`CrashKeySlot.actionIndex`).
        case requestMethod = 8
        /// The number of live terminals, as a count bucket (the app's `CrashKeySlot.terminalCount`).
        case terminalCount = 15
        /// The daemon's link to its holder (0 none, 1 connecting, 2 linked, 3 lost); the first word after the
        /// app's slots.
        case holderLinkState = 120

        /// The slot's name in a report's tags (`crash_key.<name>`).
        var name: String {
            switch self {
            case .requestMethod: "request_method"
            case .terminalCount: "terminal_count"
            case .holderLinkState: "holder_link_state"
            }
        }
    }

    /// `CMXKEYS1` as a little-endian word.
    static let magic: UInt64 = 0x3153_5945_4B58_4D43
    /// Version 1, 8 header words, 512 page words.
    static let shape: UInt64 = 1 | 8 << 16 | 512 << 32
    /// The page's size in bytes.
    static let byteCount = 512 * 8

    /// The page's file name for `role` in process `pid`, beside its black box.
    static func fileName(role: TraceRing.Role, pid: UInt32) -> String {
        "\(role.fileStem)-\(pid).crashkeys"
    }

    let pid: UInt32
    let role: UInt16
    let buildUUID: [UInt8]
    /// The set slots' values.
    let values: [Slot: UInt64]

    /// The page in `bytes`; nil when it is shorter than a page or its header is not a v1 page's.
    init?(bytes: [UInt8]) {
        guard bytes.count >= Self.byteCount else { return nil }
        func word(_ index: Int) -> UInt64 {
            (0 ..< 8).reduce(UInt64(0)) { $0 | UInt64(bytes[index * 8 + $1]) << (8 * UInt64($1)) }
        }
        guard word(0) == Self.magic, word(1) == Self.shape else { return nil }
        pid = UInt32(truncatingIfNeeded: word(2))
        role = UInt16(truncatingIfNeeded: word(2) >> 32)
        buildUUID = Array(bytes[24 ..< 40])
        var values: [Slot: UInt64] = [:]
        for slot in Slot.allCases where word(slot.rawValue) != 0 {
            values[slot] = word(slot.rawValue)
        }
        self.values = values
    }

    /// The set slots as tags: `crash_key.<name>` and a decimal value.
    var tags: [String: String] {
        Dictionary(uniqueKeysWithValues: values.map { ("crash_key.\($0.key.name)", String($0.value)) })
    }
}
