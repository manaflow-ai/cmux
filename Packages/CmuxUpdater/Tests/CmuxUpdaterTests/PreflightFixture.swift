import Foundation

struct PreflightFixture {
    let rootURL: URL
    let bundleURL: URL
    let bundle: Bundle
    let bundleIdentifier: String

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-updater-preflight-\(UUID().uuidString)", isDirectory: true)
        bundleURL = rootURL
            .appendingPathComponent("cmux.app", isDirectory: true)
        bundleIdentifier = "com.cmuxterm.test.\(UUID().uuidString)"

        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": "cmux",
            "CFBundleExecutable": "cmux",
        ]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contentsURL.appendingPathComponent("Info.plist"))

        guard let loadedBundle = Bundle(url: bundleURL) else {
            throw NSError(domain: "CmuxUpdaterTests.PreflightFixture", code: 1)
        }
        bundle = loadedBundle
    }

    var sparkleFrameworkURL: URL {
        bundleURL
            .appendingPathComponent("Contents/Frameworks/Sparkle.framework", isDirectory: true)
    }

    var sparkleCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("org.sparkle-project.Sparkle", isDirectory: true)
    }
}
