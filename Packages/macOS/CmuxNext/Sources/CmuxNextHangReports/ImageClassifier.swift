public import Foundation
import MachO

/// The facts the hang report frame rules read from this Mac (hang-reports-DESIGN.md section 3):
/// the running app's bundle (images inside it are ours), the person's words no sent name may hold,
/// and whether a bare image name exists in an Apple folder. The rules themselves (who owns an
/// image, which names may be sent, the offset cap) are Rust's, in cmux-tui/crates/cmux-hang-report,
/// asked through ``HangReportBuilder``.
///
/// ```swift
/// let classifier = ImageClassifier(appBundlePath: Bundle.main.bundlePath,
///                                  forbiddenTerms: ImageClassifier.personalTerms())
/// ```
public nonisolated struct ImageClassifier: Sendable {
    /// The running app's bundle path.
    let appBundlePath: String?
    /// The raw personal terms, read at each use (Rust lowercases them and drops the short ones
    /// and our own words).
    let terms: @Sendable () -> [String]
    /// Whether an image of that name exists in an Apple folder.
    let systemImageExists: @Sendable (String) -> Bool

    /// - Parameters:
    ///   - appBundlePath: The running app's bundle (`Bundle.main.bundlePath`); images inside it are ours.
    ///   - forbiddenTerms: Words a sent name must not hold (the user's short and full name, the
    ///     host name; ``personalTerms()``). Read at each frame or report, never at init:
    ///     ``personalTerms()`` does an OpenDirectory lookup, so the app passes a value computed
    ///     once on the first check (a utility task or the service actor).
    ///   - systemImageExists: Whether an image of that name exists in an Apple folder (the default
    ///     looks on disk); tests pass a fixed answer.
    public init(appBundlePath: String?, forbiddenTerms: @autoclosure @escaping @Sendable () -> [String],
                systemImageExists: @escaping @Sendable (String) -> Bool = { ImageClassifier.systemImageOnDisk($0) }) {
        self.appBundlePath = appBundlePath
        self.terms = forbiddenTerms
        self.systemImageExists = systemImageExists
    }

    /// Whether `/System/Library/{Frameworks,PrivateFrameworks}/<name>.framework` exists on disk,
    /// or `/usr/lib/<name>` or `/usr/lib/system/<name>` is in the dyld shared cache or on disk (a
    /// bare name with no slash; anything else is false). Since macOS 11 the system dylibs exist
    /// only in the shared cache, so a disk check alone would make `libdispatch.dylib`,
    /// `libsystem_kernel.dylib` and `libobjc.A.dylib` frames `other` once their UUID is no
    /// longer loaded (after an update).
    public static func systemImageOnDisk(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return false }
        let manager = FileManager.default
        if ["/System/Library/Frameworks/\(name).framework", "/System/Library/PrivateFrameworks/\(name).framework"]
            .contains(where: { manager.fileExists(atPath: $0) }) { return true }
        return ["/usr/lib/\(name)", "/usr/lib/system/\(name)"].contains {
            _dyld_shared_cache_contains_path($0) || manager.fileExists(atPath: $0)
        }
    }

    /// The user's short name, the words of their full name and the host name's labels: words a
    /// report must never hold.
    public static func personalTerms() -> [String] {
        let full = NSFullUserName().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // gethostname, not ProcessInfo.hostName: the latter may wait on a DNS lookup.
        var buffer = [CChar](repeating: 0, count: 256)
        let raw = gethostname(&buffer, buffer.count) == 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        let host = raw.split(separator: ".").map(String.init).filter { $0 != "local" }
        return [NSUserName(), NSHomeDirectory()] + full + host
    }
}
