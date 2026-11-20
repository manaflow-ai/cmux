import CmuxNextComputerUse
import Foundation
import Testing

@Suite struct ComputerUseRemoteBundleTests {
    @Test func setupFindsTheSameEmbeddedSupervisorAsTheDaemon() throws {
        let files = FileManager.default
        let app = files.temporaryDirectory.appending(path: "\(UUID().uuidString).app")
        defer { try? files.removeItem(at: app) }
        let library = app.appending(path: "Contents/Library")
        try files.createDirectory(at: library, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": "test.cmux.embedded", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: app.appending(path: "Contents/Info.plist"))
        let bundle = try #require(Bundle(url: app))

        func installSupervisor(_ name: String) throws -> URL {
            let helper = library.appending(path: name)
            let bin = helper.appending(path: "Contents/MacOS")
            try files.createDirectory(at: bin, withIntermediateDirectories: true)
            let executable = bin.appending(path: "cmux-remote")
            try Data().write(to: executable)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            return helper
        }

        _ = try installSupervisor("cmux Remote.app")
        #expect(ComputerUseRemoteBundle.embedded(bundle: bundle) == nil)
        let dev = try installSupervisor("cmux Computer Use (dev).app")
        #expect(ComputerUseRemoteBundle.embedded(bundle: bundle)?.appURL.path == dev.path)
        let release = try installSupervisor("cmux Computer Use.app")
        #expect(ComputerUseRemoteBundle.embedded(bundle: bundle)?.appURL.path == release.path)
    }
}
