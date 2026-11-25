import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// "My agents can turn screen sharing and control on my machines" lets agents share with no
/// dialog, so the Settings page's switch (`cmux.settings.devices.run {action: setAgentsMayShare}`)
/// turns it on only on the person's own click or key in that page, spent once; a page script, or an
/// agent driving the page, never does. Off only narrows and takes any input.
@MainActor
struct AgentsMayShareSettingsPageTests {
    final class Recorder {
        var values: [String] = []
    }

    @Test func onlyThePersonsClickTurnsAgentsMayShareOnAndOffNeedsNoClick() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-agents-may-share-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings)
        let runs = Recorder()
        page.devicesRun = { params in
            runs.values.append("\(params["action"]?.stringValue ?? "") \(params["on"]?.boolValue.map(String.init) ?? "-")")
            return .object(["ok": .bool(true)])
        }
        var backed = true
        page.personBacksGesture = { _ in backed }
        let on: JSONValue = ["action": "setAgentsMayShare", "on": true], off: JSONValue = ["action": "setAgentsMayShare", "on": false]
        let script = PageCallContext(page: PageDescriptor.settings.id)
        do {
            _ = try await page.call("cmux.settings.devices.run", params: on, context: script)
            Issue.record("a page script turned it on")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        backed = false
        do {
            _ = try await page.call("cmux.settings.devices.run", params: on,
                                    context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: 4))
            Issue.record("a synthesized click turned it on")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        backed = true
        _ = try await page.call("cmux.settings.devices.run", params: off, context: script)
        let click = PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: 9)
        _ = try await page.call("cmux.settings.devices.run", params: on, context: click)
        do {
            _ = try await page.call("cmux.settings.devices.run", params: on, context: click)
            Issue.record("one click turned it on twice")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        // Other Devices actions are unchanged.
        _ = try await page.call("cmux.settings.devices.run", params: ["action": "setSharing", "on": true], context: script)
        #expect(runs.values == ["setAgentsMayShare false", "setAgentsMayShare true", "setSharing true"])
    }
}
