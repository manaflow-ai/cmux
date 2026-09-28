/// The app Karabiner-Elements sees as frontmost while the user presses a
/// hint's keys: cmux itself.
public struct KarabinerFrontmostApplication: Sendable, Equatable {
    /// The app's bundle identifier (`com.cmuxterm.app`).
    public var bundleIdentifier: String?
    /// The path of the app's executable.
    public var executablePath: String?

    /// - Parameters:
    ///   - bundleIdentifier: The app's bundle identifier.
    ///   - executablePath: The path of the app's executable.
    public init(bundleIdentifier: String?, executablePath: String?) {
        self.bundleIdentifier = bundleIdentifier
        self.executablePath = executablePath
    }
}
