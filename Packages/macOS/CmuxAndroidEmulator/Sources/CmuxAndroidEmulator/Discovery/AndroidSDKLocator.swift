public import Foundation

/// Discovers Android SDK tools without relying on a GUI app's limited `PATH`.
public struct AndroidSDKLocator: AndroidSDKLocating, Sendable {
    private let environment: [String: String]
    private let homeDirectoryURL: URL
    private let files: any AndroidSDKFileChecking

    /// Creates an Android SDK locator with fully injected machine state.
    ///
    /// - Parameters:
    ///   - environment: Environment variables used for `ANDROID_HOME` and `ANDROID_SDK_ROOT`.
    ///   - homeDirectoryURL: The current user's home directory.
    ///   - files: Filesystem queries used to validate SDK components.
    public init(
        environment: [String: String],
        homeDirectoryURL: URL,
        files: any AndroidSDKFileChecking
    ) {
        self.environment = environment
        self.homeDirectoryURL = homeDirectoryURL
        self.files = files
    }

    /// Resolves configured SDK roots before the conventional macOS location.
    public func locate() -> AndroidSDKResolution {
        let candidates = candidateRootURLs()
        var firstExistingRoot: URL?

        for rootURL in candidates {
            guard files.directoryExists(atPath: rootURL.path) else { continue }
            firstExistingRoot = firstExistingRoot ?? rootURL

            let emulatorURL = rootURL.appendingPathComponent("emulator/emulator")
            guard files.executableExists(atPath: emulatorURL.path) else { continue }

            let adbURL = rootURL.appendingPathComponent("platform-tools/adb")
            return .available(AndroidSDKInstallation(
                rootURL: rootURL,
                emulatorURL: emulatorURL,
                adbURL: files.executableExists(atPath: adbURL.path) ? adbURL : nil
            ))
        }

        if let firstExistingRoot {
            return .emulatorMissing(rootURL: firstExistingRoot)
        }
        return .sdkNotFound
    }

    private func candidateRootURLs() -> [URL] {
        var candidates: [URL] = []
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            guard let rawValue = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !rawValue.isEmpty else {
                continue
            }
            candidates.append(URL(fileURLWithPath: rawValue, isDirectory: true).standardizedFileURL)
        }
        candidates.append(
            homeDirectoryURL
                .appendingPathComponent("Library/Android/sdk", isDirectory: true)
                .standardizedFileURL
        )

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.path).inserted }
    }
}
