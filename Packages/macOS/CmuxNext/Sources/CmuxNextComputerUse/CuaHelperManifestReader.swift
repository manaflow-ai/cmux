import Darwin
import Foundation
import os
import CmuxNextCompat
import CmuxNextWakeups

nonisolated private let manifestLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "computer-use")

/// Reads the capabilities a cmux Computer Use helper declares in
/// `cmux-cua manifest` (the top-level `capabilities` array), once per
/// helper binary (its path, modification date and size).
///
/// The wait is bounded by `timeout` on the injected clock and ends at once
/// when the caller is cancelled; the manifest process is then killed. A
/// manifest that fails, hangs or is not JSON declares nothing (an older
/// helper), is logged once, and is cached like a success. The manifest runs
/// with its own small environment; this process's environment is never
/// written (libghostty keeps a slice of `environ`).
nonisolated final class CuaHelperManifestReader: Sendable {
    /// `serve --owner-pid <pid>`: the helper exits and removes its socket when that pid exits.
    static let ownerPIDCapability = "serve.owner-pid"

    /// The app's reader. One cache per process.
    static let shared = CuaHelperManifestReader()

    private struct Key: Hashable {
        var path: String
        var modified: Date
        var size: Int
    }

    fileprivate enum Outcome: Sendable {
        case output(Data?)
        case timedOut
    }

    private let timeout: Duration
    private let clock: any Clock<Duration>
    private let cache = Mutex<[Key: Set<String>]>([:])

    init(timeout: Duration = .seconds(3), clock: any Clock<Duration> = ContinuousClock()) {
        self.timeout = timeout
        self.clock = clock
    }

    /// The capabilities of the helper app at `helper`; empty when it declares
    /// none or its manifest cannot be read.
    @concurrent func capabilities(of helper: URL) async -> Set<String> {
        let executable = Self.executable(of: helper)
        guard let key = Self.key(executable) else {
            manifestLogger.notice("cmux Computer Use helper manifest: no executable at \(executable.path, privacy: .public)")
            return []
        }
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let outcome = await Self.run(executable, timeout: timeout, clock: clock)
        // A cancelled read is not an answer about this binary: do not cache it.
        if Task.isCancelled { return [] }
        let capabilities: Set<String>
        switch outcome {
        case .timedOut:
            manifestLogger.notice("cmux Computer Use helper manifest timed out; starting without --owner-pid")
            capabilities = []
        case .output(let data):
            if let parsed = data.flatMap(Self.parse) {
                capabilities = parsed
            } else {
                manifestLogger.notice("cmux Computer Use helper manifest unreadable; starting without --owner-pid")
                capabilities = []
            }
        }
        cache.withLock { $0[key] = capabilities }
        return capabilities
    }

    /// The `capabilities` strings of a manifest; nil when it is not a JSON object.
    static func parse(_ data: Data) -> Set<String>? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Set((object["capabilities"] as? [Any] ?? []).compactMap { $0 as? String })
    }

    /// Called only from `capabilities(of:)`, which runs off the main actor.
    private static func executable(of helper: URL) -> URL {
        let plist = helper.appending(path: "Contents/Info.plist")
        // concurrency-allow: only called from @concurrent capabilities(of:), off the main actor; a small plist
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let name = info?["CFBundleExecutable"] as? String ?? "cmux-cua"
        return helper.appending(path: "Contents/MacOS/\(name)")
    }

    private static func key(_ executable: URL) -> Key? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue else { return nil }
        return Key(path: executable.path, modified: modified, size: size)
    }

    /// `<executable> manifest`'s standard output (nil when it does not
    /// start or exits nonzero), or `.timedOut` after `timeout` on `clock`.
    /// The bound and the caller's cancellation kill the process; nothing
    /// waits on a thread for it (AsyncProcess).
    private static func run(_ executable: URL, timeout: Duration, clock: any Clock<Duration>) async -> Outcome {
        let request = ProcessRequest(executable, ["manifest"], environment: [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "CMUX_CUA_TELEMETRY_ENABLED": "false",
            "CMUX_CUA_UPDATE_CHECK": "false",
        ], timeout: timeout, stopSignal: SIGKILL)
        do {
            let outcome = try await AsyncProcess(clock: clock).run(request)
            return .output(outcome.succeeded ? outcome.output : nil)
        } catch ProcessFailure.timedOut {
            return .timedOut
        } catch {
            return .output(nil)
        }
    }
}
