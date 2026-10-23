public import Foundation

/// Decides what a report may say about the image of a frame (hang-reports-DESIGN.md section 3).
///
/// An image is named only when it is ours (loaded from inside the running app bundle, or a name
/// in ``ownNamePrefixes``) or Apple's (loaded from `/System/` or `/usr/lib/`, or, for a name with
/// no loaded image, a framework or library of that exact name in those folders). The name sent is
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
    /// The folders whose images are Apple's.
    public static let applePathPrefixes = ["/System/", "/usr/lib/"]

    private let appBundlePath: String?
    private let forbiddenTerms: [String]
    private let systemImageExists: @Sendable (String) -> Bool

    /// - Parameters:
    ///   - appBundlePath: The running app's bundle (`Bundle.main.bundlePath`); images inside it are ours.
    ///   - forbiddenTerms: Words a sent name must not hold (the user's short and full name, the
    ///     host name; ``personalTerms()``), compared case-insensitively; terms under 4 letters, and
    ///     words of our own vocabulary (``isOwnWord(_:)``), are ignored.
    ///   - systemImageExists: Whether an image of that name exists in an Apple folder (the default
    ///     looks on disk); tests pass a fixed answer.
    public init(appBundlePath: String?, forbiddenTerms: [String],
                systemImageExists: @escaping @Sendable (String) -> Bool = { ImageClassifier.systemImageOnDisk($0) }) {
        self.appBundlePath = appBundlePath.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        self.forbiddenTerms = forbiddenTerms.map { $0.lowercased() }.filter { $0.count >= Self.minimumTermLength && !Self.isOwnWord($0) }
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
        guard let uuid, Self.isUUID(uuid), let offset, offset <= Self.maxOffset else { return .other }
        if let loaded { return frame(image: loaded, offset: offset) }
        guard let name, !name.isEmpty else { return .other }
        // A name that is a path is judged as a path; a bare name is ours by prefix or Apple's
        // when that framework or library exists in an Apple folder.
        let who: Owner = name.contains("/") ? owner(path: name)
            : Self.ownNamePrefixes.contains { name.hasPrefix($0) } ? .ours
            : systemImageExists(name) ? .apple : .other
        guard who != .other, let sent = sendableName(name) else { return .other }
        return HangReportFrame(image: sent, uuid: uuid.uppercased(), offset: offset)
    }

    /// Who `path` belongs to.
    public func owner(path: String) -> Owner {
        if let appBundlePath, path.hasPrefix(appBundlePath) { return .ours }
        if Self.applePathPrefixes.contains(where: { path.hasPrefix($0) }) { return .apple }
        return .other
    }

    /// The last path component of `path` when it may be sent, else nil.
    func sendableName(_ path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? ""
        guard name.range(of: Self.namePattern, options: .regularExpression) != nil else { return nil }
        let lowered = name.lowercased()
        guard !forbiddenTerms.contains(where: { lowered.contains($0) }) else { return nil }
        return name
    }

    /// Shorter personal terms are ignored: a three-letter name ("max") would refuse common words.
    static let minimumTermLength = 4

    /// A personal term that is part of our product names or of the report's fixed vocabulary
    /// ("cmux", "nightly", "apple", "stall") says nothing a report does not already say, and must
    /// not refuse every report.
    static func isOwnWord(_ term: String) -> Bool {
        ["cmux next nightly", "ghosttykit", "chromium embedded framework", "metrickit", "watchdog", "stall", "hang",
         "release", "apple", "intel", "ultra", "other", "arm64", "x86_64"].contains { $0.contains(term) }
    }

    static func isUUID(_ value: String) -> Bool {
        value.range(of: #"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"#,
                    options: .regularExpression) != nil
    }

    /// Whether `/System/Library/{Frameworks,PrivateFrameworks}/<name>.framework` or
    /// `/usr/lib/<name>` exists (a bare name with no slash; anything else is false).
    public static func systemImageOnDisk(_ name: String) -> Bool {
        guard !name.isEmpty, !name.contains("/"), !name.hasPrefix(".") else { return false }
        let manager = FileManager.default
        return ["/System/Library/Frameworks/\(name).framework", "/System/Library/PrivateFrameworks/\(name).framework",
                "/usr/lib/\(name)", "/usr/lib/system/\(name)"].contains { manager.fileExists(atPath: $0) }
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
