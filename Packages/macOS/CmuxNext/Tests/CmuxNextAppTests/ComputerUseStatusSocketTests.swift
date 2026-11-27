import AppKit
@testable import CmuxNextApp
import CmuxNextActions
import CmuxNextControl
import CmuxNextDesign
@testable import CmuxNextSettings
import Foundation
import Testing

/// `computer_use.status` over the control socket (`cmux agents doctor`): on a fresh app where
/// nothing opened Settings, onboarding or the Computer Use palette action yet, the first read
/// makes the Computer Use Setup model. With Computer Use on, it must report the helper's
/// grants as being read (`starting`), never the model's initial `off`.
@MainActor @Suite(.serialized) struct ComputerUseStatusSocketTests {
    @Test func theFirstReadOnAFreshAppDoesNotReportComputerUseOff() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cnc-cu-status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data(#"{"computerUse":{"enabled":true}}"#.utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
                                          managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        #expect(settings.snapshot.computerUse.enabled)
        _ = NSApplication.shared
        let services = AppServices(environment: AppEnvironment.current([:]))
        services.settings = settings

        let router = ControlRouter(identity: ControlIdentity(version: "1.0", build: "1", bundleID: "com.cmuxterm.app.debug.test", tag: "test",
                                                             processID: getpid()),
                                   executor: RegistryControlBridge(registry: services.registry), settings: nil,
                                   configuration: ControlRouter.Configuration(requestDeadline: .seconds(30)))
        router.register(SettingsControl.methods(services: services))
        let status = try await router.handle(ControlRequest(id: "1", method: "computer_use.status", params: [:])).get()

        guard case .object(let object) = status else {
            Issue.record("computer_use.status returned \(status)")
            return
        }
        let phase = object["phase"]?.stringValue
        #expect(phase != "off", "Computer Use is on, but the first read said off: \(status)")
        #expect(phase == "starting", "\(status)")
        #expect(object["accessibility"] == .null, "\(status)")
        #expect(object["screen_recording"] == .null, "\(status)")
        // Read-only: the status read did not change cmux.json.
        #expect(try String(contentsOf: url, encoding: .utf8) == #"{"computerUse":{"enabled":true}}"#)
    }
}
