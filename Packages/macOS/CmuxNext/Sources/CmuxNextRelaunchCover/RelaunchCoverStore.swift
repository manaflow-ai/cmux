import CCmuxLaunchShellFFI
public import CoreGraphics
public import Foundation

/// The relaunch cover's files and decisions, all in Rust (cmux-launch-shell `relaunch_cover`): the old process
/// writes each window's picture and the manifest; the new one takes a plan (shown, or why not) and drives a
/// ``RelaunchCoverReveal``. Values cross as JSON, a few calls per launch, none on a hot path.
public nonisolated struct RelaunchCoverStore {
    /// The folder beside the launch record that holds the pictures and `manifest.json`.
    public static let folderName = "relaunch-cover"
    /// A cover older than this is never shown (20 s: an update's install and relaunch take a few seconds).
    public static let maxAgeMs: UInt64 = 20_000

    public init() {}

    public static func folder(beside directory: URL) -> URL {
        directory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// Writes the manifest after the pictures; false when Rust refuses it (a name outside the folder, a bad number).
    public static func write(_ manifest: RelaunchCoverManifest, to folder: URL) -> Bool {
        guard let json = try? String(decoding: encoder.encode(manifest), as: UTF8.self), !json.utf8.contains(0),
              !folder.path.utf8.contains(0) else { return false }
        return folder.path.withCString { dir in json.withCString { cmux_relaunch_cover_write(dir, $0) } }
    }

    /// Takes the manifest (it is removed whatever it held, so at most one launch shows it) and decides. `restoring`:
    /// the ids of the windows this launch opens. A plan that does not show has already deleted its pictures.
    public static func takePlan(in folder: URL, nowMs: UInt64, displays: [RelaunchCoverDisplay],
                                restoring: [String]) -> RelaunchCoverPlan? {
        guard let restoringJSON = try? String(decoding: JSONEncoder().encode(restoring), as: UTF8.self) else { return nil }
        let cDisplays = displays.map {
            CmuxLaunchShellDisplay(x: $0.frame.origin.x, y: $0.frame.origin.y, width: $0.frame.width, height: $0.frame.height, scale: $0.scale)
        }
        let raw: String? = folder.path.withCString { dir in
            restoringJSON.withCString { restoring in
                cDisplays.withUnsafeBufferPointer { displays in
                    take(cmux_relaunch_cover_take_plan(dir, nowMs, maxAgeMs, displays.baseAddress, displays.count, restoring))
                }
            }
        }
        guard let raw, var plan = try? decoder.decode(RelaunchCoverPlan.self, from: Data(raw.utf8)) else { return nil }
        plan.json = raw
        return plan
    }

    /// Deletes the pictures `plan` named, once every cover is gone.
    public static func clear(_ plan: RelaunchCoverPlan, in folder: URL) {
        folder.path.withCString { dir in plan.json.withCString { cmux_relaunch_cover_clear(dir, $0) } }
    }

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    /// A string Rust returned, freed.
    static func take(_ pointer: UnsafeMutablePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        defer { cmux_relaunch_cover_string_free(pointer) }
        return String(cString: pointer)
    }
}

/// A display as the plan compares it: its frame (AppKit screen points) and scale.
public nonisolated struct RelaunchCoverDisplay: Sendable, Equatable {
    public var frame: CGRect
    public var scale: Double

    public init(frame: CGRect, scale: Double) {
        self.frame = frame
        self.scale = scale
    }
}

public nonisolated struct RelaunchCoverRect: Codable, Sendable, Equatable {
    public var x: Double, y: Double, width: Double, height: Double

    public init(_ rect: CGRect) {
        x = rect.origin.x; y = rect.origin.y; width = rect.width; height = rect.height
    }

    public var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
