internal import CCmuxLayoutReducerFFI
import CmuxNextCompat
public import Foundation
import os

/// Make cmux Yours' split over the Rust rules (`onboarding_walk_bundle`, `onboarding_walk_outcome`,
/// cmux-window-rules walk_split.rs): the install key is a random id made once and kept in this
/// Mac's preferences (never sent anywhere), and each walk's start and end is one JSON line in
/// `Application Support/<bundle id>/intro-walk/outcomes.jsonl` (each build its own), the records
/// `walk_split::tally` counts per bundle. Nothing here leaves the Mac; the file work runs off the
/// main actor (`IntroWalkOutcomeFile`).
@MainActor
public final class IntroWalkSplitLog: IntroWalkSplitSource {
    public static let installKeyPreference = "introWalkInstallKey"
    /// This Mac's log: `Application Support/<bundle id>/intro-walk/outcomes.jsonl` (each build its own).
    public static let shared = IntroWalkSplitLog(file: NextSupport.applicationSupportDirectory()
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.cmuxterm.app.next", isDirectory: true)
        .appendingPathComponent("intro-walk", isDirectory: true)
        .appendingPathComponent("outcomes.jsonl", isDirectory: false))

    private let defaults: UserDefaults
    public let file: IntroWalkOutcomeFile
    /// The last append; each waits for the one before, so the records keep their order.
    private var lastWrite: Task<Void, Never>?

    public init(defaults: UserDefaults = .standard, file: URL) {
        self.defaults = defaults
        self.file = IntroWalkOutcomeFile(url: file)
    }

    /// This install's key: made once, the same every launch, so its bundle never reshuffles.
    public var installKey: String {
        if let key = defaults.string(forKey: Self.installKeyPreference), !key.isEmpty { return key }
        let key = UUID().uuidString.lowercased()
        defaults.set(key, forKey: Self.installKeyPreference)
        return key
    }

    private struct BundleRequest: Encodable { var installKey: String }
    private struct BundleReply: Decodable { var id: String }
    private struct OutcomeRequest: Encodable { var bundle: String; var ending: IntroWalkEnding; var screen: Int }

    public func bundle() -> String? {
        Self.call("onboarding_walk_bundle", BundleRequest(installKey: installKey), as: BundleReply.self)?.id
    }

    public func record(bundle: String, ending: IntroWalkEnding, screen: Int) {
        guard let outcome = Self.call("onboarding_walk_outcome",
                                      OutcomeRequest(bundle: bundle, ending: ending, screen: max(0, screen)),
                                      as: IntroWalkOutcome.self) else { return }
        Self.log.info("intro walk \(ending.rawValue, privacy: .public) bundle \(bundle, privacy: .public) screen \(screen)")
        let file = file, previous = lastWrite
        // task-owner: the log's append chain; a walk's record outlives the window that logged it.
        lastWrite = Task {
            await previous?.value
            await file.append(outcome)
        }
    }

    /// One JSON call of the app FFI; nil when it does not answer (a pinned FFI without the op).
    private static func call<Request: Encodable, Reply: Decodable>(_ operation: String, _ request: Request, as: Reply.Type) -> Reply? {
        guard let data = try? JSONEncoder().encode(request) else { return nil }
        var capacity = 1024
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = data.withUnsafeBytes { bytes in
                operation.withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, data.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { break }
            return try? JSONDecoder().decode(Reply.self, from: Data(output.prefix(length)))
        }
        log.fault("intro walk rule \(operation, privacy: .public) did not answer")
        return nil
    }

    private static let log = Logger(subsystem: "com.cmuxterm.app.next", category: "intro-walk")
}

/// One walk's record (`cmux_window_rules::walk_split::Outcome`).
public struct IntroWalkOutcome: Codable, Equatable, Sendable {
    public var version: Int
    public var bundle: String
    public var ending: IntroWalkEnding
    public var screen: Int

    public init(version: Int, bundle: String, ending: IntroWalkEnding, screen: Int) {
        self.version = version
        self.bundle = bundle
        self.ending = ending
        self.screen = screen
    }
}

/// The walk records' file, appended and read off the main actor, one JSON line each.
public actor IntroWalkOutcomeFile {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func append(_ outcome: IntroWalkOutcome) {
        guard var line = try? JSONEncoder().encode(outcome) else { return }
        line.append(0x0A)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: line)
            } else {
                try line.write(to: url, options: .atomic)
            }
        } catch {
            Logger(subsystem: "com.cmuxterm.app.next", category: "intro-walk")
                .error("intro walk record not written: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The records written so far, oldest first (tests, the probe).
    public func records() -> [IntroWalkOutcome] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(IntroWalkOutcome.self, from: Data($0)) }
    }
}
