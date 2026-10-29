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
@MainActor @Suite(.serialized) struct SettingsWideningSwitchPersonGateTests {
    @MainActor final class Recorder {
        var sets: [String] = []
    }

    /// The Touch ID or password confirm: answers `answer`, or, when `hold`, waits for ``resume(_:)`` (a
    /// cancel answers false). Every wait here ends: a second held ask while one is up answers false at
    /// once and is counted in `overlaps`, and ``held(_:)`` also returns when the request ends first.
    @MainActor final class FakeOwner: DeviceOwnerAuthenticating {
        var answer = false
        var hold = false
        var reasons: [String] = []
        var overlaps = 0
        private var pending: CheckedContinuation<Bool, Never>?
        private var asked: (wait: Int, continuation: CheckedContinuation<Void, Never>)?
        private var waits = 0

        func authenticate(reason: String) async -> Bool {
            reasons.append(reason)
            guard hold else { return answer }
            guard pending == nil else {
                overlaps += 1
                return false
            }
            return await withTaskCancellationHandler {
                await withCheckedContinuation {
                    pending = $0
                    wake()
                }
            } onCancel: {
                Task { @MainActor in self.resume(false) }
            }
        }

        /// Whether `request`'s confirm is up: returns once it is, or once `request` ended without one.
        func held(_ request: Task<JSONValue, any Error>) async -> Bool {
            if pending == nil {
                waits += 1
                let wait = waits
                // task-owner: wakes this wait (only this one) when the request ends first; ends with the request.
                Task { @MainActor in
                    _ = try? await request.value
                    self.wake(wait)
                }
                await withCheckedContinuation { asked = (wait, $0) }
            }
            return pending != nil
        }

        func resume(_ answer: Bool) {
            pending?.resume(returning: answer)
            pending = nil
        }

        /// Wakes the waiting ``held(_:)``: any (a confirm came up), or only wait `wait` (its request ended).
        private func wake(_ wait: Int? = nil) {
            guard let asked, wait == nil || wait == asked.wait else { return }
            asked.continuation.resume()
            self.asked = nil
        }
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
            let cgEvent = try #require(CGEvent(mouseEventSource: CGEventSource(stateID: .hidSystemState), mouseType: .leftMouseUp,
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

        /// A posted click's on for `op`, left running while its confirm is held.
        func heldOn(_ op: Switch) throws -> Task<JSONValue, any Error> {
            let event = try posted()
            ledger.record(event)
            let page = page, stamp = event.timestamp
            return Task {
                try await page.call(op.rawValue, params: ["id": "m1", "on": true],
                                    context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true, gestureEvent: stamp))
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
        var reason: String {
            self == .fullAccess ? SettingsPersonGateStrings.fullAccessReason : SettingsPersonGateStrings.vmHostReason
        }
    }

    private func make(owner: FakeOwner?) async throws -> Harness {
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
        page.ownerConfirm = owner
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
        let h = try await make(owner: nil)
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

    @Test func thePersonsOwnClickTurnsItOnWithNoPrompt() async throws {
        let owner = FakeOwner()
        let h = try await make(owner: owner)
        defer { h.cleanUp() }
        for op in Switch.allCases {
            #expect(try await !h.refused(op, on: true, h.click(0)))
        }
        #expect(h.recorder.sets == ["device true", "vm true"])
        #expect(owner.reasons.isEmpty, "a person's local click gets no new prompt")
        // A posted click right after the person's backs nothing: it asks, and a cancel turns nothing on.
        let mine = try h.click(0)
        h.ledger.record(mine)
        #expect(try await h.refused(.fullAccess, on: true, h.posted()))
        #expect(owner.reasons == [Switch.fullAccess.reason])
        #expect(h.recorder.sets == ["device true", "vm true"])
    }

    /// Screen Sharing, Universal Control, the Accessibility Keyboard or a posted click: the owner confirms
    /// with Touch ID or the password, with the switch's own reason; only a success turns it on.
    @Test func aClickThatIsNotTheHIDSystemsAsksTheOwnerAndOnlyASuccessTurnsItOn() async throws {
        let owner = FakeOwner()
        let h = try await make(owner: owner)
        defer { h.cleanUp() }
        for op in Switch.allCases {
            owner.answer = false
            #expect(try await h.refused(op, on: true, h.posted()), "a cancelled confirm turned \(op) on")
            #expect(owner.reasons.last == op.reason)
            #expect(!h.recorder.sets.contains("\(op.set) true"))
            owner.answer = true
            #expect(try await !h.refused(op, on: true, h.posted()))
            #expect(h.recorder.sets.last == "\(op.set) true")
        }
        #expect(owner.reasons == [Switch.fullAccess.reason, Switch.fullAccess.reason, Switch.vmHost.reason, Switch.vmHost.reason])
        #expect(Switch.fullAccess.reason != Switch.vmHost.reason)
        // Off never asks.
        for op in Switch.allCases { #expect(try await !h.refused(op, on: false, h.posted())) }
        #expect(owner.reasons.count == 4)
    }

    /// The click is spent before the confirm: a cancelled confirm's click, sent again, asks nothing and
    /// turns nothing on, and a page script with no click never reaches the confirm.
    @Test func aCancelledConfirmsClickIsSpentAndScriptNeverAsks() async throws {
        let owner = FakeOwner()
        let h = try await make(owner: owner)
        defer { h.cleanUp() }
        let posted = try h.posted()
        #expect(try await h.refused(.vmHost, on: true, posted))
        owner.answer = true
        #expect(try await h.refused(.vmHost, on: true, posted), "the same click again")
        do {
            _ = try await h.page.call(Switch.fullAccess.rawValue, params: ["id": "m1", "on": true],
                                      context: PageCallContext(page: PageDescriptor.settings.id))
            Issue.record("page script turned it on")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(owner.reasons.count == 1)
        #expect(h.recorder.sets.isEmpty)
    }

    /// One confirm at a time: while one is up, a second posted click is refused without a second prompt
    /// (an agent cannot stack prompts behind the person's), and the first still turns on only its switch.
    @Test(.timeLimit(.minutes(1))) func aSecondAskWhileOneIsUpIsRefused() async throws {
        let owner = FakeOwner()
        owner.hold = true
        let h = try await make(owner: owner)
        defer {
            owner.resume(false)
            h.cleanUp()
        }
        let asking = try h.heldOn(.fullAccess)
        #expect(await owner.held(asking))
        #expect(owner.reasons.count == 1)
        #expect(try await h.refused(.vmHost, on: true, h.posted()))
        #expect(owner.reasons.count == 1 && owner.overlaps == 0, "no second prompt")
        owner.resume(true)
        _ = try await asking.value
        #expect(h.recorder.sets == ["device true"])
    }

    /// An off while that switch's confirm is up wins: the confirm's late success turns nothing back on.
    /// An off of the other switch leaves the confirm standing.
    @Test(.timeLimit(.minutes(1))) func anOffWhileTheConfirmIsUpVoidsIt() async throws {
        let owner = FakeOwner()
        owner.hold = true
        let h = try await make(owner: owner)
        defer {
            owner.resume(false)
            h.cleanUp()
        }
        for op in Switch.allCases {
            let asking = try h.heldOn(op)
            #expect(await owner.held(asking))
            #expect(try await !h.refused(op, on: false, h.posted()))
            owner.resume(true)
            do {
                _ = try await asking.value
                Issue.record("a confirm that outlived an off turned \(op) back on")
            } catch let error as PageError {
                #expect(error.code == PageNativeOp.userOnlyCode)
            }
        }
        #expect(h.recorder.sets == ["device false", "vm false"])
        let asking = try h.heldOn(.vmHost)
        #expect(await owner.held(asking))
        #expect(try await !h.refused(.fullAccess, on: false, h.posted()))
        owner.resume(true)
        _ = try await asking.value
        #expect(h.recorder.sets == ["device false", "vm false", "device false", "vm true"])
    }
}
