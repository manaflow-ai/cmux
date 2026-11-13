import CmuxNextApps
import Foundation
import Testing

/// The one toggle for the user's custom sidebar (`sidebar.custom.toggle`, Lawrence 2026-11-09: "make it
/// easier to toggle the custom sidebar"): what one press does in each state, and the starter it writes
/// when there is no customize folder yet.
struct CustomSidebarToggleTests {
    private func record(installed: Bool = true, enabled: Bool = true, hidden: Bool = false) throws -> AppRecord {
        let manifest = try #require(AppManifest(json: ["id": "local/customize", "manifestVersion": 2, "version": "1.0.0"]))
        return AppRecord(manifest: manifest, tier: .unverified, installed: installed, enabled: enabled, hidden: hidden, source: .local)
    }

    @Test func aShownSidebarHidesInOnePress() throws {
        let state = CustomSidebarState(record: try record())
        #expect(state == .shown)
        #expect(state.toggleChange == .hide(true))
    }

    @Test func aHiddenSidebarShowsInOnePress() throws {
        let state = CustomSidebarState(record: try record(hidden: true))
        #expect(state == .hidden)
        #expect(state.toggleChange == AppChange(enabled: true, hidden: false))
    }

    /// Turned off in the App Store reads as hidden, and one press turns it back on too.
    @Test func aTurnedOffSidebarShowsAndTurnsOn() throws {
        let off = try record(enabled: false)
        let state = CustomSidebarState(record: off)
        #expect(state == .hidden)
        #expect(state.toggleChange?.applied(to: off).isVisible == true)
    }

    @Test func noInstalledAppOffersTheStarter() throws {
        #expect(CustomSidebarState(record: nil) == .missing)
        #expect(CustomSidebarState(record: try record(installed: false)) == .missing)
        #expect(CustomSidebarState.missing.toggleChange == nil)
    }

    @Test func theFolderIsTheOneTheDaemonWatches() {
        #expect(CustomizeFolder(environment: ["CMUX_CUSTOMIZE_DIR": "/x/c", "XDG_CONFIG_HOME": "/x/cfg", "HOME": "/x/h"])?.url.path() == "/x/c/")
        #expect(CustomizeFolder(environment: ["CMUX_CUSTOMIZE_DIR": "", "XDG_CONFIG_HOME": "/x/cfg", "HOME": "/x/h"])?.url.path() == "/x/cfg/cmux/customize")
        #expect(CustomizeFolder(environment: ["HOME": "/x/h"])?.url.path() == "/x/h/.config/cmux/customize")
        #expect(CustomizeFolder(environment: [:]) == nil)
    }

    @Test func theStarterIsAnInstallableSidebarSection() async throws {
        let files = FileManager()
        let dir = files.temporaryDirectory.appending(path: "customize-\(UUID().uuidString)")
        defer { try? files.removeItem(at: dir) }
        let folder = CustomizeFolder(url: dir)
        #expect(try await folder.writeStarter())
        let manifest = try #require(AppManifest.decode(try Data(contentsOf: folder.manifestURL)))
        #expect(manifest.id == "local/customize")
        #expect(manifest.implementations.contains { $0.interface == "cmux.section/1" })
        let script = try String(contentsOf: folder.scriptURL, encoding: .utf8)
        #expect(script.contains("__cmuxAppExports"))
    }

    @Test func theStarterNeverOverwritesTheUsersFiles() async throws {
        let files = FileManager()
        let dir = files.temporaryDirectory.appending(path: "customize-\(UUID().uuidString)")
        defer { try? files.removeItem(at: dir) }
        let folder = CustomizeFolder(url: dir)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("mine".utf8).write(to: folder.scriptURL)
        #expect(try await folder.writeStarter())
        #expect(try String(contentsOf: folder.scriptURL, encoding: .utf8) == "mine")
        try Data("{}".utf8).write(to: folder.manifestURL)
        #expect(try await folder.writeStarter() == false)
        #expect(try String(contentsOf: folder.manifestURL, encoding: .utf8) == "{}")
    }
}
