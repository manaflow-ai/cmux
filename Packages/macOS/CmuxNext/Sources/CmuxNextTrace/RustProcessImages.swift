/// Which image names in another cmux process's stack are cmux's own binaries: the Rust
/// processes' executables (`cmux-tui`, `cmux-holder`, `acpmux`, its agent host, `optchat-chief`).
///
/// One list for both readers of a Rust hang line: the Sentry event marks these frames in-app (`RustHangRecord`) and
/// the hang report names them as ours (`ImageClassifier.frame(foreign:loaded:)`), so the two never disagree.
///
/// ```swift
/// RustProcessImages.cmux.contains("acpmux") // true
/// ```
public struct RustProcessImages: Sendable, Equatable {
    /// The image name prefixes (case-sensitive).
    public let prefixes: [String]

    /// The names that start with one of `prefixes`.
    public init(prefixes: [String]) {
        self.prefixes = prefixes
    }

    /// cmux's shipped Rust binaries.
    public static let cmux = RustProcessImages(prefixes: ["cmux", "acpmux", "optchat"])

    /// Whether the image file `name` (no folder) is one of them.
    public func contains(_ name: String) -> Bool {
        prefixes.contains { name.hasPrefix($0) }
    }
}
