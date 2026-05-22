import Foundation

public struct BrowserEngineConfiguration: Equatable, Sendable {
    public let chromiumHostPath: String
    public let mojoRuntimePath: String
    public let userDataRootPath: String
    public let devToolsEnabled: Bool

    public init(
        chromiumHostPath: String,
        mojoRuntimePath: String,
        userDataRootPath: String,
        devToolsEnabled: Bool
    ) {
        self.chromiumHostPath = chromiumHostPath
        self.mojoRuntimePath = mojoRuntimePath
        self.userDataRootPath = userDataRootPath
        self.devToolsEnabled = devToolsEnabled
    }

    public var isConfigured: Bool {
        !chromiumHostPath.isEmpty && !mojoRuntimePath.isEmpty
    }

    public static func fromEnvironment() -> BrowserEngineConfiguration {
        let environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let bundledChromiumRoot = Bundle.main.resourceURL?
            .appendingPathComponent("Chromium", isDirectory: true)
            .path
        return BrowserEngineConfiguration(
            chromiumHostPath: firstExistingPath([
                environment["MINIMAL_BROWSER_CHROMIUM_HOST"],
                environment["OWL_CHROMIUM_HOST"],
                bundledChromiumRoot.map { "\($0)/Content Shell.app/Contents/MacOS/Content Shell" },
                "\(home)/chromium/src/out/Release/Content Shell.app/Contents/MacOS/Content Shell"
            ]),
            mojoRuntimePath: firstExistingPath([
                environment["MINIMAL_BROWSER_MOJO_RUNTIME_PATH"],
                environment["OWL_MOJO_RUNTIME_PATH"],
                bundledChromiumRoot.map { "\($0)/libowl_fresh_mojo_runtime.dylib" },
                "\(home)/chromium/src/out/Release/libowl_fresh_mojo_runtime.dylib"
            ]),
            userDataRootPath: environment["MINIMAL_BROWSER_USER_DATA_ROOT"]
                ?? "\(home)/Library/Application Support/minimal-browser/Profiles",
            devToolsEnabled: boolValue(environment["MINIMAL_BROWSER_DEVTOOLS_ENABLED"], defaultValue: true)
        )
    }

    private static func firstExistingPath(_ candidates: [String?]) -> String {
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else {
                continue
            }
            if FileManager.default.fileExists(atPath: NSString(string: candidate).expandingTildeInPath) {
                return NSString(string: candidate).expandingTildeInPath
            }
        }
        return ""
    }

    private static func boolValue(_ rawValue: String?, defaultValue: Bool) -> Bool {
        guard let rawValue else {
            return defaultValue
        }
        switch rawValue.lowercased() {
        case "0", "false", "no", "off":
            return false
        case "1", "true", "yes", "on":
            return true
        default:
            return defaultValue
        }
    }
}
