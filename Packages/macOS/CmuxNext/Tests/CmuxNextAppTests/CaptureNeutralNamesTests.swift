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

    @Test func aPersonsRunKeepsTheirShellAndThisMacsName() {
        let plain = AppEnvironment.current([:])
        #expect(plain.captureShellHome == nil)
        #expect(plain.terminalEnvironment["ZDOTDIR"] == nil)
        #expect(plain.terminalEnvironment["SHELL"] == nil)
        #expect(!plain.namesShowcaseMac)
    }
}
