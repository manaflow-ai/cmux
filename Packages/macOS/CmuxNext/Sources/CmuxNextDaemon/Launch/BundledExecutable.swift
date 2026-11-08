public import CmuxNextWakeups
public import Foundation
import CmuxNextCompat

/// One executable this app bundle carries (`<Resources>/bin/<name>`, such as the bundled `cmux`), or the one an
/// override names: a cmux-tui built from source (`CMUX_NEXT_TUI_BIN`, ``DaemonLauncher/binaryOverrideKey``) runs in
/// place of the bundled `cmux`, so a CLI change is tried in the installed app with no app build.
///
/// Its callers ask on the main thread (an action's availability check, a page's registration), so asking makes
/// no file system call: whether the file is there is read once on the files lane of ``BackgroundWork`` and kept,
/// since the bundle does not change while the app runs. The app makes one per executable (AppServices) and passes
/// it to each caller.
public final class BundledExecutable: Sendable {
    /// Where the executable is when this build carries it; nil when the bundle has no resources folder.
    public let candidate: URL?
    private let work: BackgroundWork
    /// Whether ``candidate`` is an executable file: nil until ``resolve()`` has read it.
    private let present = Mutex<Bool?>(nil)

    /// - Parameters:
    ///   - resources: The bundle's resources folder (`Bundle.main.resourceURL`).
    ///   - name: The executable's file name in `bin`.
    ///   - work: The app's blocking-work lanes: the one file system read runs on `.files`.
    ///   - override: An executable to run instead of the bundled one; nil or empty keeps the bundle's.
    public init(resources: URL?, name: String, work: BackgroundWork, override: String? = nil) {
        if let override, !override.isEmpty {
            candidate = URL(fileURLWithPath: override)
        } else {
            candidate = resources?.appendingPathComponent("bin", isDirectory: true).appendingPathComponent(name)
        }
        self.work = work
    }

    /// The app's `cmux`: `CMUX_NEXT_TUI_BIN` when set (the same binary the daemon then runs, since `bin/cmux-tui`
    /// is `bin/cmux`), else `<Resources>/bin/cmux`.
    public static func cli(resources: URL?, work: BackgroundWork,
                           environment: [String: String] = ProcessInfo.processInfo.environment) -> BundledExecutable {
        BundledExecutable(resources: resources, name: "cmux", work: work, override: environment[DaemonLauncher.binaryOverrideKey])
    }

    /// The executable, or nil when this build does not carry it. The first call reads the file system on the
    /// files lane; later calls answer at once. A read the caller's cancel dropped is not kept.
    public func resolve() async -> URL? {
        guard let candidate else { return nil }
        if let known = present.withLock({ $0 }) { return known ? candidate : nil }
        let path = candidate.path
        guard let found = try? await work.run(.userVisible, mayBlock: .files, { FileManager.checked.isExecutableFile(atPath: path) })
        else { return nil }
        present.withLock { $0 = found }
        return found ? candidate : nil
    }

    /// What is known now, with no file system call, for a caller that cannot wait (an action's availability):
    /// the executable once ``resolve()`` found it, nil once it found none or when there is no bundle, and the
    /// candidate before the first answer (running a missing executable then fails with its own error).
    public var known: URL? { present.withLock { $0 } == false ? nil : candidate }
}
