import CmuxNextCompat
import CmuxNextControl
import Foundation
import Testing
@testable import CmuxNextApp

/// A run under PR capture (`CMUX_CAPTURE_SHELL_HOME`, named by cmuxterm-hq capture-host in the slot clone's
/// `LSEnvironment`) shows no host name: its panes name the showcase Mac, as a showcase run does, and its
/// terminals' zsh reads the slot's neutral rc files. Before: a tour capture on a fleet mini was refused by
/// the privacy check for the mini's name in the composer's machine chip and in the zsh prompt (`cmux@<host> ~ %`).
@MainActor
struct CaptureNeutralNamesTests {
    @Test func aCaptureSlotsShellHomeIsReadOnlyAsAnAbsoluteFolder() {
        let folder = { (path: String) in path == "/lease/home" }
        #expect(AppEnvironment.captureShellHome(["CMUX_CAPTURE_SHELL_HOME": "/lease/home"], isFolder: folder) == "/lease/home")
        #expect(AppEnvironment.captureShellHome(["CMUX_CAPTURE_SHELL_HOME": "lease/home"], isFolder: { _ in true }) == nil)
        #expect(AppEnvironment.captureShellHome(["CMUX_CAPTURE_SHELL_HOME": "/missing"], isFolder: folder) == nil)
        #expect(AppEnvironment.captureShellHome([:], isFolder: { _ in true }) == nil)
    }

    @Test func underCaptureTerminalsStartZshFromTheSlotsShellHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("capture-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let captured = AppEnvironment.current(["CMUX_CAPTURE_SHELL_HOME": home.path])
        #expect(captured.captureShellHome == home.path)
        #expect(captured.terminalEnvironment["ZDOTDIR"] == home.path)
        #expect(captured.terminalEnvironment["SHELL"] == "/bin/zsh")
        #expect(captured.namesShowcaseMac)
    }

    @Test func theTerminalEnvironmentAndTheMacsNameAgreeOnACapture() {
        let folder = { (path: String) in path == "/lease/home" }
        for path in ["/lease/home", "/missing", "lease/home"] {
            let environment = ["CMUX_CAPTURE_SHELL_HOME": path]
            #expect(AppEnvironment.captureShellHome(environment, isFolder: folder) == MacName.captureShellHome(environment, isFolder: folder))
        }
    }

    @Test func aRunUnderCaptureIsNeverThePlacedServer() {
        #expect(ServerReachService.thisMac(captureOverride: MacName.captureName) == nil)
    }

    /// A media tour (scripts/cmux-next/media/tour.py) launches a DEBUG build with the shell home in its environment,
    /// not in the bundle's `LSEnvironment`. Before: the launch strip dropped it as an inherited `CMUX*` variable, so
    /// the tour's shots showed the CI Mac's prompt and name and pr-media's privacy check published none of them.
    @Test func aDebugLaunchKeepsATourShellHomeButNotOneFromAnotherCmux() {
        let tour = ["CMUX_CAPTURE_SHELL_HOME": "/tmp/tour/shell-home"]
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: tour, bundledEnvironment: [:], isDebugBuild: true).isEmpty)
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: tour, bundledEnvironment: [:], isDebugBuild: false)
            == ["CMUX_CAPTURE_SHELL_HOME"])
        // A terminal of a capture app carries it with that app's socket: a cmux started there is not under capture.
        let nested = tour.merging(["CMUX_SOCKET_PATH": "/tmp/other.sock"]) { $1 }
        #expect(LaunchIdentity.inheritedKeys(processEnvironment: nested, bundledEnvironment: [:], isDebugBuild: true)
            .contains("CMUX_CAPTURE_SHELL_HOME"))
    }

    @Test func aPersonsRunKeepsTheirShellAndThisMacsName() {
        let plain = AppEnvironment.current([:])
        #expect(plain.captureShellHome == nil)
        #expect(plain.terminalEnvironment["ZDOTDIR"] == nil)
        #expect(plain.terminalEnvironment["SHELL"] == nil)
        #expect(!plain.namesShowcaseMac)
    }
}
