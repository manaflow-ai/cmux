import Foundation

/// Loads the isolated JavaScript runtime shipped with ``CmuxBrowser``.
public struct BrowserDesignModeScript: Sendable {
    private static let resourceBundleName = "CmuxBrowser_CmuxBrowser"
    private static let runtimeResourceName = "BrowserDesignModeRuntime"
    private let resourceURL: URL?

    /// Creates a runtime script loader.
    public init() {
        self.init(resourceURL: Self.defaultResourceURL())
    }

    init(resourceURL: URL?) {
        self.resourceURL = resourceURL
    }

    /// Loads the bundled runtime source.
    /// - Returns: The JavaScript source to evaluate in an isolated WebKit content world.
    /// - Throws: A Cocoa file error when the resource cannot be found or decoded.
    @concurrent
    public func source() async throws -> String {
        guard let resourceURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try String(contentsOf: resourceURL, encoding: .utf8)
    }

    private static func defaultResourceURL() -> URL? {
        var resourceBundleURLs: [URL] = []
        #if DEBUG
        if let overridePath = ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_PATH"]
            ?? ProcessInfo.processInfo.environment["PACKAGE_RESOURCE_BUNDLE_URL"]
        {
            resourceBundleURLs.append(URL(fileURLWithPath: overridePath, isDirectory: true))
        }
        #endif

        let candidateDirectories = [
            Bundle.main.resourceURL,
            Bundle(for: BrowserDesignModeScriptBundleFinder.self).resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.bundleURL.deletingLastPathComponent(),
            Bundle(for: BrowserDesignModeScriptBundleFinder.self).bundleURL.deletingLastPathComponent(),
        ]
        resourceBundleURLs.append(contentsOf: candidateDirectories.compactMap { candidateDirectory in
            candidateDirectory?.appendingPathComponent(
                resourceBundleName + ".bundle",
                isDirectory: true
            )
        })

        for resourceBundleURL in resourceBundleURLs {
            guard let resourceBundle = Bundle(url: resourceBundleURL) else { continue }
            if let resourceURL = resourceBundle.url(
                forResource: runtimeResourceName,
                withExtension: "js"
            ) {
                return resourceURL
            }
        }
        return nil
    }
}

private final class BrowserDesignModeScriptBundleFinder {}
