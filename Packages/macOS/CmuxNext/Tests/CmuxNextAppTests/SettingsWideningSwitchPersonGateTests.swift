import AppKit
import CmuxNextActions
import CmuxNextAgentPane
import CmuxNextDesign
import CmuxNextPages
@testable import CmuxNextSettings
import Foundation
import Testing
@testable import CmuxNextApp

/// Settings' Full access (a paired device) and Dedicated agent machine (a Cloud machine's vmHost)
/// switches widen what another machine may do here, so an agent driving this Mac's screen must not turn
/// them on. An on needs the person's own click in the page, and that click must be the HID system's
/// (``PersonInputLedger``, ``PersonInputCheck``). Any other click (a computer-use agent's posted one,
/// Screen Sharing) asks for Touch ID or the password (`ownerConfirm`), and only a confirm that succeeds
/// turns it on. An off takes any input.
/// RED variant (the base before the gate): only the posted-click test.
@MainActor @Suite(.serialized) struct SettingsWideningSwitchPersonGateTests {
    @MainActor final class Recorder {
        var sets: [String] = []
    }

    @MainActor final class Harness {
        let page: SettingsPageProvider
        let recorder: Recorder
        let ledger: PersonInputLedger
        let directory: URL
        let poster: Process
        var second: UInt64 = 100

        init(page: SettingsPageProvider, recorder: Recorder, ledger: PersonInputLedger, directory: URL, poster: Process) {
            self.page = page
            self.recorder = recorder
            self.ledger = ledger
            self.directory = directory
            self.poster = poster
        }

        /// A left click as the page's local monitor sees it: from a HID-state source, with `pid` as its
        /// source pid (0: the HID system; the poster's: a process that posted it, as the cmux-cua helper does).
        func click(_ pid: Int64) throws -> NSEvent {
            second += 1
            // No CGEventSource: making a HID-state source can deadlock inside SkyLight on a mini with no
            // console session. The fields the check reads are set by hand below.
            let cgEvent = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                               mouseCursorPosition: .zero, mouseButton: .left))
            cgEvent.setIntegerValueField(.eventSourceUnixProcessID, value: pid)
            cgEvent.setIntegerValueField(.eventSourceStateID, value: Int64(CGEventSourceStateID.hidSystemState.rawValue))
            cgEvent.timestamp = second * 1_000_000_000
            return try #require(NSEvent(cgEvent: cgEvent))
        }

        func posted() throws -> NSEvent { try click(Int64(poster.processIdentifier)) }

        /// The page's call for `op` on `event` (the gesture the page recorded is the event's own time);
        /// true when it was refused as not the person's.
        func refused(_ op: Switch, on: Bool, _ event: NSEvent) async throws -> Bool {
            ledger.record(event)
            do {
                _ = try await page.call(op.rawValue, params: ["id": "m1", "on": .bool(on)],
                                        context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: event.timestamp))
                return false
            } catch let error as PageError where error.code == PageNativeOp.userOnlyCode {
                return true
            }
        }

        func cleanUp() {
            poster.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    enum Switch: String, CaseIterable {
        case fullAccess = "cmux.settings.devices.full_access"
        case vmHost = "cmux.settings.machines.vm_host"

        var set: String { self == .fullAccess ? "device" : "vm" }
    }

    private func make() async throws -> Harness {
        let directory = FileManager.default.temporaryDirectory.appending(path: "cn-settings-person-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "cmux.json")
        try Data("{}".utf8).write(to: url)
        let settings = SettingsController(registry: ActionRegistry(catalog: []), design: DesignSettings(), fileURL: url,
            managedReader: FixedManagedPreferenceReader(ManagedPreferences()), managedWatchFiles: [])
        await settings.reload()
        let page = SettingsPageProvider(settings: settings)
        let recorder = Recorder()
        page.setDeviceFullAccess = { _, on in recorder.sets.append("device \(on)"); return nil }
        page.setMachineVmHost = { _, on in recorder.sets.append("vm \(on)"); return nil }
        let ledger = PersonInputLedger()
        page.personBacksGesture = { ledger.backs($0) }
        // A live process other than this one and the WindowServer, standing in for the poster.
        let poster = Process()
        poster.executableURL = URL(fileURLWithPath: "/bin/sleep")
        poster.arguments = ["30"]
        try poster.run()
        return Harness(page: page, recorder: recorder, ledger: ledger, directory: directory, poster: poster)
    }

    /// RED before this change: a click another process posted from a HID-state source turned either
    /// switch on, since the page saw a real event. Now it turns neither on (this Mac cannot ask the
    /// owner here), and the same posted click turns both off.
    @Test func aPostedClickTurnsNeitherSwitchOnButTurnsBothOff() async throws {
        let h = try await make()
        defer { h.cleanUp() }
        for op in Switch.allCases {
            #expect(try await h.refused(op, on: true, h.posted()), "a posted click turned \(op) on")
        }
        #expect(h.recorder.sets.isEmpty, "nothing reached acpmux or the machine")
        for op in Switch.allCases {
            #expect(try await !h.refused(op, on: false, h.posted()))
        }
        #expect(h.recorder.sets == ["device false", "vm false"], "off takes any input")
    }
}
