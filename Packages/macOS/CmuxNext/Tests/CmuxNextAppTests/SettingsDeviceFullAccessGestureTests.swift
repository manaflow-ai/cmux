import CmuxNextActions
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Settings > Devices' Full access switch: page script alone never turns a machine's Full
/// access on. On needs the person's own click or key in the Settings page, and one gesture
/// turns on one setting; off needs none.
@MainActor struct SettingsDeviceFullAccessGestureTests {
    @MainActor final class Recorder {
        var sets: [String] = []
    }

    private func make() async throws -> (page: SettingsPageProvider, recorder: Recorder, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-full-access-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings)
        let recorder = Recorder()
        page.setDeviceFullAccess = { id, on in recorder.sets.append("\(id) \(on)"); return nil }
        page.ownerConfirm = SettingsWideningSwitchPersonGateTests.AlwaysConfirms() // the confirm: SettingsWideningSwitchPersonGateTests
        page.personBacksGesture = { _ in true }
        return (page, recorder, directory)
    }

    private func params(on: Bool) -> JSONValue { ["id": "paired:dv_leo", "on": .bool(on)] }

    private func refused(_ page: SettingsPageProvider, on: Bool, _ context: PageCallContext) async -> Bool {
        do {
            _ = try await page.call("cmux.settings.devices.full_access", params: params(on: on), context: context)
            return false
        } catch let error as PageError {
            return error.code == PageNativeOp.userOnlyCode
        } catch {
            return false
        }
    }

    @Test func pageScriptAloneNeverTurnsAMachinesFullAccessOn() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let script = PageCallContext(page: PageDescriptor.settings.id)
        // A page can claim neither a gesture nor the user: the host records both.
        let claimsUser = PageCallContext(page: PageDescriptor.settings.id, origin: "user")
        let otherPage = PageCallContext(page: "cmux.history", userGesture: true, gestureEvent: 7)
        #expect(await refused(h.page, on: true, script))
        #expect(await refused(h.page, on: true, claimsUser))
        #expect(await refused(h.page, on: true, otherPage))
        #expect(h.recorder.sets.isEmpty, "a refused on never reaches acpmux")
    }

    @Test func oneClickTurnsOneSettingOnAndOffNeedsNoClick() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let click = PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: 42)
        _ = try await h.page.call("cmux.settings.devices.full_access", params: params(on: true), context: click)
        #expect(h.recorder.sets == ["paired:dv_leo true"])
        // The same click again (a script riding the person's gesture) is refused.
        #expect(await refused(h.page, on: true, click))
        // Off only narrows what the machine may do: it never needs a gesture.
        _ = try await h.page.call("cmux.settings.devices.full_access", params: params(on: false),
                                  context: PageCallContext(page: PageDescriptor.settings.id))
        let next = PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: 43)
        _ = try await h.page.call("cmux.settings.devices.full_access", params: params(on: true), context: next)
        #expect(h.recorder.sets == ["paired:dv_leo true", "paired:dv_leo false", "paired:dv_leo true"])
    }
}
