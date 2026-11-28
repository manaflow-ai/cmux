import AppKit
@testable import CmuxNextDesign
import Foundation
import Testing

/// The Computer Use drag rows (onboarding's and the agent permission card's) never show the generic
/// blank app: a helper bundle that names no icon draws Computer Use's bundled icon, one that names
/// its own draws that.
@Suite struct ComputerUseAppIconTests {
    /// A temporary `<name>.app` with an Info.plist of `info` and, when given, Resources files.
    private static func app(info: [String: String], resources: [String] = []) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(path: "cu-icon-\(UUID().uuidString)", directoryHint: .isDirectory)
        let app = root.appending(path: "cmux DEV Helper.app", directoryHint: .isDirectory)
        let contents = app.appending(path: "Contents", directoryHint: .isDirectory)
        let resourceFolder = contents.appending(path: "Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resourceFolder, withIntermediateDirectories: true)
        var plist: [String: String] = ["CFBundleIdentifier": "com.cmuxterm.app.debug.screen-sharing", "CFBundlePackageType": "APPL"]
        plist.merge(info) { $1 }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
        for name in resources {
            try Data("icns".utf8).write(to: resourceFolder.appending(path: name))
        }
        return app
    }

    @Test func bundledIconIsTheRealComputerUseIcon() throws {
        let icon = try #require(ComputerUseAppIcon.bundled)
        // The .icns "cmux Computer Use.app" ships: every size up to 512 pt, not a placeholder.
        #expect(icon.representations.count > 1)
        #expect(icon.size.width >= 32)
    }

    @Test func helperWithoutAnIconDrawsComputerUses() throws {
        let app = try Self.app(info: [:])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(!ComputerUseAppIcon.declaresIcon(app))
        let bundled = try #require(ComputerUseAppIcon.bundled)
        let image = ComputerUseAppIcon.image(forApp: app)
        #expect(image.tiffRepresentation == bundled.tiffRepresentation)
    }

    @Test func iconFileNamedButMissingIsNoIcon() throws {
        let app = try Self.app(info: ["CFBundleIconFile": "AppIcon"])
        defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
        #expect(!ComputerUseAppIcon.declaresIcon(app))
    }

    @Test func helperWithItsOwnIconKeepsIt() throws {
        for (info, resources) in [(["CFBundleIconFile": "AppIcon"], ["AppIcon.icns"]),
                                  (["CFBundleIconFile": "AppIcon.icns"], ["AppIcon.icns"]),
                                  (["CFBundleIconName": "AppIcon"], ["Assets.car"])] {
            let app = try Self.app(info: info, resources: resources)
            defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
            #expect(ComputerUseAppIcon.declaresIcon(app), "\(info)")
        }
    }

    @Test func noBundleIsNoIcon() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID().uuidString).app")
        #expect(!ComputerUseAppIcon.declaresIcon(missing))
    }
}
