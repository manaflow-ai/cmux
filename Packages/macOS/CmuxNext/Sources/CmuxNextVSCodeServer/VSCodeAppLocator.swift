import CmuxNextCompat
public import Foundation

/// Finds the installed VS Code app: by bundle id, else the usual install places; Insiders last.
///
/// Lookups go through the injected closures (the app passes NSWorkspace's
/// `urlForApplication(withBundleIdentifier:)`), so this changes nothing and a menu row's
/// availability can ask it on every open.
public struct VSCodeAppLocator {
    private let homeDirectory: String
    private let fileExists: (String) -> Bool
    private let application: (String) -> URL?

    /// - Parameters:
    ///   - homeDirectory: The user's home, for `~/Applications`.
    ///   - fileExists: Whether a path exists. Defaults to the file system.
    ///   - application: The app with a bundle id, or nil.
    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                fileExists: ((String) -> Bool)? = nil,
                application: @escaping (String) -> URL?) {
        self.homeDirectory = homeDirectory
        self.fileExists = fileExists ?? { FileManager.checked.fileExists(atPath: $0) }
        self.application = application
    }

    /// The VS Code app, or nil when none is installed.
    public func installed() -> URL? {
        if let url = application("com.microsoft.VSCode") { return url }
        for path in ["/Applications/Visual Studio Code.app", "\(homeDirectory)/Applications/Visual Studio Code.app", "/Applications/Code.app"]
            where fileExists(path) {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return application("com.microsoft.VSCodeInsiders")
    }
}
