import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Computer Use may act in cmux itself and in terminals by default (Leo, 2026-11-22, on "Computer Use
/// isn't allowed to act there.": "why not. it should be able to"). So an agent driving cmux's Settings
/// page must not change Settings > Computer Use: a `computerUse.*` write, a reset and Reset All need the
/// person's own HID click or key in the page. A click another process posted, or a page call with no
/// gesture, is refused; every other row still takes any page interaction.
@MainActor @Suite(.serialized) struct SettingsComputerUsePersonGateTests {
    @MainActor final class Harness {
        let page: SettingsPageProvider
        let settings: SettingsController
        let ledger: PersonInputLedger
        let directory: URL
        var second: UInt64 = 100

        init(page: SettingsPageProvider, settings: SettingsController, ledger: PersonInputLedger, directory: URL) {
            self.page = page
            self.settings = settings
            self.ledger = ledger
            self.directory = directory
        }

        /// A left click from a HID-state source with `pid` as its source pid (0: the HID system).
        func click(_ pid: Int64) throws -> NSEvent {
            second += 1
            let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                               mouseCursorPosition: .zero, mouseButton: .left))
            cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
            cgEvent.setIntegerValueField(.eventSourceStateID, value: Int64(CGEventSourceStateID.hidSystemState.rawValue))
            cgEvent.timestamp = second * 1_000_000_000
            return try #require(NSEvent(cgEvent: cgEvent))
        }

        /// True when `op` on `params`, backed by `event` (nil: no gesture), was refused as not the person's.
        func refused(_ op: String, _ params: JSONValue, _ event: NSEvent?) async throws -> Bool {
            if let event { ledger.record(event) }
            let context = PageCallContext(page: PageDescriptor.settings.id, userGesture: event != nil, gestureEvent: event?.timestamp)
            do {
                _ = try await page.call(op, params: params, context: context)
                return false
            } catch let error as PageError where error.code == PageNativeOp.userOnlyCode {
                return true
            }
        }
    }

    private func make() async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-cu-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(writer: TestSettingsWriter(), registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings)
        let ledger = PersonInputLedger(check: { event in
            event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == 0
        })
        page.personBacksGesture = { ledger.backs($0) }
        return Harness(page: page, settings: settings, ledger: ledger, directory: directory)
    }

    @Test func onlyThePersonsOwnInputChangesComputerUseSettings() async throws {
        let h = try await make()
        defer { try? FileManager.default.removeItem(at: h.directory) }
        let poster = Int64(ProcessInfo.processInfo.processIdentifier) + 1
        let widen: [(String, JSONValue)] = [
            ("cmux.settings.set", ["key": "computerUse.deniedApps", "value": .array([])]),
            ("cmux.settings.set", ["key": "computerUse.allowForeground", "value": true]),
            ("cmux.settings.reset", ["key": "computerUse.deniedApps"]),
            ("cmux.settings.reset_all", [:]),
        ]
        for (op, params) in widen {
            #expect(try await h.refused(op, params, h.click(poster)), "a posted click ran \(op) \(params)")
            #expect(try await h.refused(op, params, nil), "a call with no gesture ran \(op) \(params)")
        }
        #expect(h.settings.snapshot.computerUse.deniedApps == ComputerUseSettings.defaultDeniedApps)
        #expect(!h.settings.snapshot.computerUse.allowForeground)
        // The person's own click changes it.
        #expect(try await !h.refused("cmux.settings.set", ["key": "computerUse.allowForeground", "value": true], h.click(0)))
        // Other rows still take any interaction with the page.
        #expect(try await !h.refused("cmux.settings.set", ["key": "computerUse.showCursor", "value": false], h.click(0)))
        #expect(try await !h.refused("cmux.settings.set", ["key": "appearance.density", "value": "comfortable"], h.click(poster)))
    }
}
