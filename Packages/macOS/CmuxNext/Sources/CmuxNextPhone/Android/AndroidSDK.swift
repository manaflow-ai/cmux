public import Foundation

/// Where the user's Android SDK lives. cmux ships no Android tools: it uses
/// the `adb` and `emulator` that Android Studio (or `sdkmanager`) installed.
public struct AndroidSDK: Sendable, Hashable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `platform-tools/adb`.
    public var adb: String { root.appendingPathComponent("platform-tools/adb").path }
    /// `emulator/emulator`.
    public var emulator: String { root.appendingPathComponent("emulator/emulator").path }

    /// The first SDK with an `adb`: `ANDROID_HOME`, then `ANDROID_SDK_ROOT`,
    /// then Android Studio's default `~/Library/Android/sdk`. Nil when none.
    /// - Parameters:
    ///   - environment: the process environment (tests pass their own).
    ///   - home: the user's home folder.
    ///   - fileExists: checks a path (tests fake the file system).
    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> AndroidSDK? {
        let candidates = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]].compactMap { $0 }.filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) } + [home.appendingPathComponent("Library/Android/sdk")]
        return candidates.map(AndroidSDK.init(root:)).first { fileExists($0.adb) }
    }
}
