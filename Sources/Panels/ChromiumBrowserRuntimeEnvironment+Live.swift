import CmuxBrowser
import Foundation

extension ChromiumBrowserRuntimeEnvironment {
    /// Live dependencies are captured once at the executable composition
    /// boundary. The browser package never reaches into process-wide globals.
    static let cmuxLive: ChromiumBrowserRuntimeEnvironment = {
        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
        let bundleIdentifier = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
        let executableOverride = ProcessInfo.processInfo.environment["CMUX_CHROMIUM_EXECUTABLE"]
            .flatMap { value in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : URL(fileURLWithPath: trimmed)
            }
        let loopbackConfiguration = URLSessionConfiguration.ephemeral
        loopbackConfiguration.connectionProxyDictionary = [:]
        loopbackConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        loopbackConfiguration.timeoutIntervalForRequest = 10
        let loopbackSession = URLSession(configuration: loopbackConfiguration)

        return ChromiumBrowserRuntimeEnvironment(
            fileManager: fileManager,
            runtimeDownloadSession: URLSession.shared,
            loopbackCDPSession: loopbackSession,
            applicationSupportURLProvider: { applicationSupportURL },
            bundleIdentifierProvider: { bundleIdentifier },
            executableOverrideProvider: { executableOverride },
            startupDeadline: {
                try await ContinuousClock().sleep(for: .seconds(30))
            }
        )
    }()
}
