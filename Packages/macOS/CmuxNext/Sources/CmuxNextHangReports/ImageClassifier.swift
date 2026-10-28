import CmuxNextTrace
public import Foundation
import MachO
import CmuxNextCompat

/// Decides what a report may say about the image of a frame (hang-reports-DESIGN.md section 3).
///
/// An image is named only when it is ours (loaded from inside the running app bundle, or a name
/// in ``ownNamePrefixes``) or Apple's (loaded from `/System/` or `/usr/lib/` on the sealed system
/// volume or an OS cryptex, or, for a name with no loaded image, a framework or library of that
/// exact name in those folders). `/System/Volumes/` (the firmlinked Data volume holds every user's
/// files there), the firmlinked writable folders under `/System/Library/`, and any path with `.`,
/// `..` or empty components are never Apple's. The name sent is
/// the last path component, and only when it matches ``namePattern`` and holds none of
/// ``forbiddenTerms``. Every other image is ``HangReportFrame/other``: no name, UUID or offset.
///
/// ```swift
/// let classifier = ImageClassifier(appBundlePath: Bundle.main.bundlePath,
///                                  forbiddenTerms: ImageClassifier.personalTerms())
/// let frame = classifier.frame(image: loaded, offset: 0x1234)
/// ```
public nonisolated struct ImageClassifier: Sendable {
    /// Who an image belongs to.
    public enum Owner: Sendable, Equatable {
        case ours
        case apple
        case other
    }

    /// Image names that are ours wherever they load from (prefix match, case-sensitive).
    public static let ownNamePrefixes = ["cmux", "Cmux", "GhosttyKit", "Chromium Embedded Framework", "Sparkle", "Sentry"]
    /// The characters and length a sent image name may have.
    public static let namePattern = #"^[A-Za-z0-9 ._+()\-]{1,64}$"#
    /// The largest offset a frame may name (the server's limit, 2^40).
    public static let maxOffset: UInt64 = 1 << 40
    /// The folders whose images are Apple's (minus ``notApplePathPrefixes``).
    public static let applePathPrefixes = ["/System/", "/usr/lib/"]
    /// Folders under ``applePathPrefixes`` that are not the sealed system volume: `/System/Volumes/`
    /// holds the Data volume (`/System/Volumes/Data/Users/<name>/...`) and other writable volumes,
    /// and the firmlinked folders below live on the Data volume.
    public static let notApplePathPrefixes = [
        "/System/Volumes/", "/System/Library/Caches/", "/System/Library/Assets/", "/System/Library/AssetsV2/",
        "/System/Library/PreinstalledAssets/", "/System/Library/PreinstalledAssetsV2/", "/System/Library/Speech/",
        "/System/Library/CoreServices/CoreTypes.bundle/Contents/Library/",
    ]
    /// The OS cryptexes under `/System/Volumes/`: Apple's sealed images (macOS 13 and later).
    public static let cryptexSystemPrefixes = [
        "/System/Volumes/Preboot/Cryptexes/OS/System/", "/System/Volumes/Preboot/Cryptexes/App/System/",
    ]

    private let appBundlePath: String?
    private let forbiddenTerms: @Sendable () -> [String]
    private let systemImageExists: @Sendable (String) -> Bool

    /// - Parameters:
    ///   - appBundlePath: The running app's bundle (`Bundle.main.bundlePath`); images inside it are ours.
    ///   - forbiddenTerms: Words a sent name must not hold (the user's short and full name, the
    ///     host name; ``personalTerms()``), compared case-insensitively; terms under 4 letters, and
    ///     words of our own vocabulary (``isOwnWord(_:)``), are ignored. Read at each name
    ///     check, never at init: ``personalTerms()`` does an OpenDirectory lookup, so the app
    ///     passes a value computed once on the first check (a utility task or the service actor).
    ///   - systemImageExists: Whether an image of that name exists in an Apple folder (the default
    ///     looks on disk); tests pass a fixed answer.
    public init(appBundlePath: String?, forbiddenTerms: @autoclosure @escaping @Sendable () -> [String],
                systemImageExists: @escaping @Sendable (String) -> Bool = { ImageClassifier.systemImageOnDisk($0) }) {
        self.appBundlePath = appBundlePath.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        self.forbiddenTerms = { Self.normalizedTerms(forbiddenTerms()) }
        self.systemImageExists = systemImageExists
    }

    /// The frame for an address in `image` (from ``ImageResolving``), or ``HangReportFrame/other``.
    public func frame(image: LoadedImage?, address: UInt64) -> HangReportFrame {
        guard let image, image.contains(address) else { return .other }
        return frame(image: image, offset: address - image.base)
    }

    /// The frame at `offset` into a loaded image, or ``HangReportFrame/other``.
    public func frame(image: LoadedImage, offset: UInt64) -> HangReportFrame {
        guard offset <= Self.maxOffset, owner(path: image.path) != .other, let name = sendableName(image.path) else { return .other }
        return HangReportFrame(image: name, uuid: image.uuid, offset: offset)
    }

    /// The frame of a MetricKit call stack frame: `loaded` is the image with its UUID in this
    /// process (nil when none matches, for example after an update), `name` MetricKit's
    /// `binaryName`.
    public func frame(metricKitName name: String?, uuid: String?, offset: UInt64?, loaded: LoadedImage?) -> HangReportFrame {
        frame(name: name, uuid: uuid, offset: offset, loaded: loaded, ownNames: nil)
    }

    /// The frame of another cmux process's stack (a Rust hang line), whose image is not loaded here: as a MetricKit
    /// frame, and a bare name of one of cmux's Rust binaries (``RustProcessImages/cmux``, the list the line's Sentry
    /// event marks in-app with) is ours too.
    public func frame(foreign: HangReportCollector.ForeignFrame, loaded: LoadedImage?) -> HangReportFrame {
        frame(name: foreign.image, uuid: foreign.uuid, offset: foreign.offset, loaded: loaded, ownNames: .cmux)
    }

    private func frame(name: String?, uuid: String?, offset: UInt64?, loaded: LoadedImage?,
                       ownNames: RustProcessImages?) -> HangReportFrame {
        guard let uuid, Self.isUUID(uuid), let offset, offset <= Self.maxOffset else { return .other }
        if let loaded { return frame(image: loaded, offset: offset) }
        guard let name, !name.isEmpty else { return .other }
        // A name that is a path is judged as a path; a bare name is ours by prefix or Apple's
        // when that framework or library exists in an Apple folder.
        let who: Owner = name.contains("/") ? owner(path: name)
            : Self.ownNamePrefixes.contains { name.hasPrefix($0) } || ownNames?.contains(name) == true ? .ours
            : systemImageExists(name) ? .apple : .other
        guard who != .other, let sent = sendableName(name) else { return .other }
        return HangReportFrame(image: sent, uuid: uuid.uppercased(), offset: offset)
    }

    /// Who `path` belongs to.
    public func owner(path: String) -> Owner {
        // `/usr/lib/../../Users/x/libhook.dylib` starts with an Apple folder but is not in one.
        guard Self.isPlainAbsolutePath(path) else { return .other }
        if let appBundlePath, path.hasPrefix(appBundlePath) { return .ours }
        if Self.cryptexSystemPrefixes.contains(where: { path.hasPrefix($0) }) { return .apple }
        if Self.notApplePathPrefixes.contains(where: { path.hasPrefix($0) }) { return .other }
        if Self.applePathPrefixes.contains(where: { path.hasPrefix($0) }) { return .apple }
        return .other
    }

    /// Whether `path` is absolute with no empty, `.` or `..` component (dyld reports a path as it
    /// was given, for example through `DYLD_INSERT_LIBRARIES`).
    static func isPlainAbsolutePath(_ path: String) -> Bool {
        guard path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The last path component of `path` when it may be sent, else nil.
    func sendableName(_ path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        guard name.range(of: Self.namePattern, options: .regularExpression) != nil else { return nil }
        let lowered = name.lowercased()
        guard !forbiddenTerms().contains(where: { lowered.contains($0) }) else { return nil }
        return name
    }

    /// `terms` lowercased, without the short ones and our own words.
    static func normalizedTerms(_ terms: [String]) -> [String] {
        terms.map { $0.lowercased() }.filter { $0.count >= minimumTermLength && !isOwnWord($0) }
    }

    /// Shorter personal terms are ignored: a three-letter name ("max") would refuse common words.
    static let minimumTermLength = 4

    /// A personal term that is part of our product names or of the report's fixed vocabulary
    /// ("cmux", "nightly", "apple", "stall") says nothing a report does not already say, and must
    /// not refuse every report. The input latency labels are not here: the leak scan accepts them
    /// only as exact values at their own keys (``PrivacyLeakScanner/closedSetValues``), so a
    /// name inside one ("mina" in `terminal`) still refuses an image or any other string.
    static func isOwnWord(_ term: String) -> Bool {
        ownVocabulary.contains { $0.contains(term) }
    }

    /// Our product names and the report's fixed string values, lowercased. The launch temperatures
    /// and completion reasons come from their enums, so a new case is covered ("lukewarm" holds the
    /// name "luke", "visiblePaneTimedOut" the word "pane").
    static let ownVocabulary: [String] = [
        "cmux next nightly", "ghosttykit", "chromium embedded framework", "metrickit", "watchdog", "stall", "hang",
        "release", "apple", "intel", "ultra", "other", "arm64", "x86_64",
    ] + LaunchTemperature.allCases.map { $0.rawValue.lowercased() }
        + LaunchCompletionReason.allCases.map { $0.rawValue.lowercased() }

    static func isUUID(_ value: String) -> Bool {
        value.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                    options: .regularExpression) != nil
    }

    /// Whether `/System/Library/{Frameworks,PrivateFrameworks}/<name>.framework` exists on disk,
    /// or `/usr/lib/<name>` or `/usr/lib/system/<name>` is in the dyld shared cache or on disk (a
    /// bare name with no slash; anything else is false). Since macOS 11 the system dylibs exist
    /// only in the shared cache, so a disk check alone would make `libdispatch.dylib`,
    /// `libsystem_kernel.dylib` and `libobjc.A.dylib` frames `other` once their UUID is no
    /// longer loaded (after an update).
    public static func systemImageOnDisk(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return false }
        if ["/System/Library/Frameworks/\(name).framework", "/System/Library/PrivateFrameworks/\(name).framework"]
            .contains(where: { FileManager.checked.fileExists(atPath: $0) }) { return true }
        return ["/usr/lib/\(name)", "/usr/lib/system/\(name)"].contains {
            // SAFETY: the path is passed as a NUL-terminated temporary copy that lives for the call; dyld only reads it.
            unsafe _dyld_shared_cache_contains_path($0) || FileManager.checked.fileExists(atPath: $0)
        }
    }

    /// The user's short name, the words of their full name and the host name's labels: words a
    /// report must never hold.
    public static func personalTerms() -> [String] {
        let full = NSFullUserName().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        // gethostname, not ProcessInfo.hostName: the latter may wait on a DNS lookup.
        var buffer = [CChar](repeating: 0, count: 256)
        // SAFETY: gethostname writes at most buffer.count bytes into `buffer`, a local array live for the call.
        let raw = unsafe gethostname(&buffer, buffer.count) == 0
            ? String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) : ""
        let host = raw.split(separator: ".").map(String.init).filter { $0 != "local" }
        return [NSUserName(), NSHomeDirectory()] + full + host
    }
}
