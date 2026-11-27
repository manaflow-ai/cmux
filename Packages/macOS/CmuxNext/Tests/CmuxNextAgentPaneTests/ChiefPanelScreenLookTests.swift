import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextDictation
@testable import CmuxNextSettings
import Foundation
import Testing

/// The floating Chief's one look at the screen when it opens (``ChiefPanelScreenLook``) waits for Computer Use: with
/// it off, opening the panel never asks for the screen share (whose helper a look would start, or wait 2 s on), even
/// with the eye on. A share asked for is a look; the fake returns none, so nothing is captured.
@MainActor
@Suite(.serialized)
struct ChiefPanelScreenLookTests {
    /// A settings controller over a temporary cmux.json holding `json`.
    static func settings(_ json: String) async throws -> (SettingsController, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-chief-look-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data(json.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        return (settings, directory)
    }

    /// How many times opening the panel asked for the screen share under `json`.
    static func looks(_ json: String) async throws -> Int {
        let (settings, directory) = try await settings(json)
        defer { try? FileManager.default.removeItem(at: directory) }
        var asked = 0
        let look = ChiefPanelScreenLook(share: { asked += 1; return nil }, settings: { settings })
        look.panelOpened(window: "cmux")
        return asked
    }

    @Test(arguments: [
        (#"{}"#, 0, "Computer Use is off by default"),
        (#"{"computerUse": {"enabled": false}}"#, 0, "Computer Use off"),
        (#"{"computerUse": {"enabled": true}, "home": {"chiefPanel": {"seesScreen": false}}}"#, 0, "the eye off"),
        (#"{"computerUse": {"enabled": true}}"#, 1, "Computer Use on and the eye on by default"),
    ])
    func theLookWaitsForComputerUseAndTheEye(json: String, expected: Int, why: String) async throws {
        #expect(try await Self.looks(json) == expected, "\(why): \(json)")
    }
}
