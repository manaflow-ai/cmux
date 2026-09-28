import Foundation
import Testing
@testable import CmuxComputerUse

/// A synthetic host bundle and private home; no test can target the stable app.
struct HelperRuntimeFixture {
    let files: HelperBundleFixture
    let bundle: Bundle
    let nestedHelper: URL
    let paths: ComputerUseRuntimePaths

    init() throws {
        files = try HelperBundleFixture()
        let host = files.root.appendingPathComponent("Host.app")
        nestedHelper = host.appendingPathComponent("Contents/Library/cmux Computer Use.app")
        try FileManager.default.createDirectory(at: nestedHelper.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: files.bundle, to: nestedHelper)
        let info = try PropertyListSerialization.data(fromPropertyList: [
            "CFBundleIdentifier": "com.cmuxterm.tests.\(UUID().uuidString)",
            "CFBundleName": "Helper host fixture",
            "CFBundlePackageType": "APPL"
        ], format: .xml, options: 0)
        try info.write(to: host.appendingPathComponent("Contents/Info.plist"))
        bundle = try #require(Bundle(url: host))
        paths = ComputerUseRuntimePaths(
            homeDirectoryURL: files.root,
            socketRootDirectoryURL: files.root,
            environment: [:],
            bundleIdentifier: "helper-tests",
            authenticationToken: "fixture-token",
            hostAuthenticationToken: "fixture-host-token"
        )
    }
}
