import CmuxNextCompat
import Foundation
import Testing

/// The state every build still shared after `BuildStatePaths` (the user, 2026-11-16: "for dev builds we must make
/// sure that all such values and configurations have a dev build isolation that prevents each dev build from deriving
/// state from each other even from prod"): the `cmux vm` config, the MCP tool lists, the mux plugins and classic
/// cmux's data. A DEV build names its own to its Rust children; NIGHTLY and stable keep the shared ones.
/// And the state named after the bundle id (the Chief home, the mobile host, the browser profiles) is named after
/// the build key in a DEV build, so two Debug copies of one bundle id with their own tags never share it.
@Suite struct DevBuildSharedStateTests {
    static let home = URL(fileURLWithPath: "/Users/me", isDirectory: true)
    static let support = home.appendingPathComponent("Library/Application Support", isDirectory: true)
    static let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)

    static func paths(_ bundleID: String?, tag: String? = nil) -> BuildStatePaths {
        BuildStatePaths(build: BuildIdentity(bundleID: bundleID, bundledTag: tag), userHome: home,
                        applicationSupport: support, caches: caches)
    }

    static let keys = ["CMUX_VM_DEFAULT_CONFIG", "CMUX_NEXT_MCP_UPSTREAMS_DIR", "CMUX_NEXT_MUX_PLUGINS_DIR",
                       "CMUX_NEXT_CLASSIC_IMPORT_DIR"]

    @Test func aDevBuildsChildrenGetItsOwnVMConfigToolListsPluginsAndClassicFolder() {
        let dev = Self.paths("com.cmuxterm.app.debug.my-tag").environment
        let root = "/Users/me/Library/Application Support/cmux-next/builds/com.cmuxterm.app.debug.my-tag"
        #expect(dev["CMUX_VM_DEFAULT_CONFIG"] == root + "/config/vm.json")
        #expect(dev["CMUX_NEXT_MCP_UPSTREAMS_DIR"] == "/Users/me/Library/Caches/cmux-next/builds/com.cmuxterm.app.debug.my-tag/mcp-upstreams")
        #expect(dev["CMUX_NEXT_MUX_PLUGINS_DIR"] == root + "/mux-plugins")
        #expect(dev["CMUX_NEXT_CLASSIC_IMPORT_DIR"] == root + "/classic-import")
        let other = Self.paths("com.cmuxterm.app.debug.other-tag").environment
        for key in Self.keys {
            #expect(dev[key] != nil && dev[key] != other[key], "\(key) is shared by two tags")
        }
    }

    @Test func sharedBuildsKeepTheRustDefaults() {
        for build in [Self.paths("com.cmuxterm.app.nightly"), Self.paths("com.cmuxterm.app.nightly.cmux-next"),
                      Self.paths("com.cmuxterm.app"), Self.paths(nil)] {
            for key in Self.keys { #expect(build.environment[key] == nil, "\(build.build.key) sets \(key)") }
        }
    }

    /// The daemon and acpmux get only allow-listed variables: the build's settings defaults are one of them.
    @Test func childrenGetTheSettingsBuildDefaults() {
        let value = #"{"mobile.allowIPhoneConnections":true}"#
        let child = BuildStatePaths.childEnvironment(from: ["CMUX_NEXT_SETTINGS_BUILD_DEFAULTS": value, "PATH": "/usr/bin"])
        #expect(child["CMUX_NEXT_SETTINGS_BUILD_DEFAULTS"] == value)
        #expect(child["PATH"] == nil)
    }

    /// A Debug copy of the plain DEV bundle names its state after its build key; a tagged DEV build
    /// (`com.cmuxterm.app.debug.<tag>`), NIGHTLY, cmux NEXT and release keep their bundle id's folder.
    @Test func stateNamedAfterTheBundleIdFollowsTheBuildKeyInADevBuild() {
        let copyA = BuildIdentity(bundleID: "com.cmuxterm.app.debug", bundledTag: "copy-a")
        let copyB = BuildIdentity(bundleID: "com.cmuxterm.app.debug", bundledTag: "copy-b")
        #expect(copyA.stateFolderName(for: "com.cmuxterm.app.debug") == "com.cmuxterm.app.debug--copy-a")
        #expect(copyB.stateFolderName(for: "com.cmuxterm.app.debug") == "com.cmuxterm.app.debug--copy-b")
        // Migration: the folders that exist today stay.
        let kept = ["com.cmuxterm.app.debug.my-tag", "com.cmuxterm.app.debug.a.b", "com.cmuxterm.app.nightly",
                    "com.cmuxterm.app.nightly.cmux-next", "com.cmuxterm.app", "com.cmuxterm.app.staging.my-tag"]
        for id in kept {
            // As built (reload.sh ships the id's tag in LSEnvironment) and with no LSEnvironment.
            for tag in [nil, BuildIdentity(bundleID: id, bundledTag: nil).tag] {
                #expect(BuildIdentity(bundleID: id, bundledTag: tag).stateFolderName(for: id) == id, "\(id) moved")
            }
        }
        #expect(BuildIdentity(bundleID: "com.cmuxterm.app.debug", bundledTag: nil).stateFolderName(for: "com.cmuxterm.app.debug")
                == "com.cmuxterm.app.debug")
        // Another bundle id than the build's is that bundle's own folder.
        #expect(copyA.stateFolderName(for: "com.cmuxterm.app.nightly") == "com.cmuxterm.app.nightly")
        #expect(copyA.stateFolderName(for: nil) == nil)
    }

    /// A `cmux DEV <tag>.app` copy whose Info.plist lost `LSEnvironment` is the tagged build, as LaunchIdentity
    /// and the `cmux` CLI (app_identity.rs) read it: it never collapses onto the untagged DEV build's state.
    @Test func aCopyNamedForItsTagThatLostLSEnvironmentKeepsItsKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bsp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func bundle(_ name: String, tag: String?) throws -> Bundle {
            let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info: [String: Any] = ["CFBundleIdentifier": "com.cmuxterm.app.debug", "CFBundlePackageType": "APPL",
                                       "CFBundleExecutable": "cmux"]
            if let tag { info["LSEnvironment"] = ["CMUX_TAG": tag] }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            return try #require(Bundle(url: root.appendingPathComponent("\(name).app", isDirectory: true)))
        }
        #expect(BuildIdentity(bundle: try bundle("cmux DEV copy-a", tag: nil)).key == "com.cmuxterm.app.debug--copy-a")
        #expect(BuildIdentity(bundle: try bundle("cmux DEV Copy B", tag: nil)).key == "com.cmuxterm.app.debug--copy-b")
        // The shipped tag wins over the name; an untagged name is the untagged build.
        #expect(BuildIdentity(bundle: try bundle("cmux DEV name", tag: "shipped")).key == "com.cmuxterm.app.debug--shipped")
        #expect(BuildIdentity(bundle: try bundle("cmux DEV", tag: nil)).key == "com.cmuxterm.app.debug")
    }
}
