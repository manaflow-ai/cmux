import Foundation

/// Production Android SDK filesystem checker.
public struct SystemAndroidSDKFileChecker: AndroidSDKFileChecking, Sendable {
    /// Creates a system filesystem checker.
    public init() {}

    /// Implements ``AndroidSDKFileChecking/directoryExists(atPath:)``.
    public func directoryExists(atPath path: String) -> Bool {
        var isDirectory = ObjCBool(false)
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// Implements ``AndroidSDKFileChecking/executableExists(atPath:)``.
    public func executableExists(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}
