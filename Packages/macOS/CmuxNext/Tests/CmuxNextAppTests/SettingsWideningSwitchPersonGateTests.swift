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
/// them on. An on needs the person's own click in the page and then Touch ID or the password
/// (`ownerConfirm`), whatever the click's source fields say: a poster can set those. Only a confirm that
/// succeeds turns it on. An off takes any input, with no prompt, and wins over every on asked before it.
@MainActor @Suite(.serialized) struct SettingsWideningSwitchPersonGateTests {
    @MainActor final class Recorder {
        var sets: [String] = []
    }

    /// A confirm that always succeeds, for tests about the click rather than the confirm.
    @MainActor final class AlwaysConfirms: DeviceOwnerAuthenticating {
        func authenticate(reason: String) async -> Bool { true }
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

    /// Host writes whose on is held until the test lands it; an off lands at once. Every wait here ends:
    /// ``arrived(_:)`` also returns when its request ends first or is cancelled.
    @MainActor final class Landing {
        private var held: [CheckedContinuation<Void, Never>] = []
        private var waiting: (wait: Int, continuation: CheckedContinuation<Void, Never>)?
        private var waits = 0

        func write(_ name: String, _ on: Bool, _ recorder: Recorder) async -> String? {
            if on {
                await withCheckedContinuation {
                    held.append($0)
                    wake()
                }
            }
            recorder.sets.append("\(name) \(on)")
            return nil
        }

        /// Whether an on's write is held: returns once one is, or once `request` ended without one.
        func arrived(_ request: Task<JSONValue, any Error>) async -> Bool {
            if held.isEmpty {
                waits += 1
                let wait = waits
                // task-owner: wakes this wait (only this one) when the request ends first; ends with the request.
                Task { @MainActor in
                    _ = try? await request.value
                    self.wake(wait)
                }
                await withTaskCancellationHandler {
                    await withCheckedContinuation { waiting = (wait, $0) }
                } onCancel: {
                    Task { @MainActor in self.wake() }
                }
            }
            return !held.isEmpty
        }

        /// Lands the oldest held on.
        func land() {
            guard !held.isEmpty else { return }
            held.removeFirst().resume()
        }

        /// Lands every held write and wakes any wait (cleanup).
        func release() {
            while !held.isEmpty { land() }
            wake()
        }

        private func wake(_ wait: Int? = nil) {
            guard let waiting, wait == nil || wait == waiting.wait else { return }
            waiting.continuation.resume()
            self.waiting = nil
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

        /// An on for `op` from a click by `pid` (default: a posted click), left running.
        func heldOn(_ op: Switch, pid: Int64? = nil) throws -> Task<JSONValue, any Error> {
            let event = try click(pid ?? Int64(poster.processIdentifier))
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
        /// The gate's key for machine `id` (``SettingsPageProvider/widen(_:_:reason:on:_:_:)``).
        func key(_ id: String) -> String { self == .fullAccess ? "fullAccess \(id)" : "vmHost \(id)" }
        var reason: String {
            self == .fullAccess ? RemoteStrings.fullAccessConfirmReason : RemoteStrings.vmHostConfirmReason
        }
    }

    /// Waits (bounded) for the provider to reach a state another task puts it in.
    private static func until(_ reached: @MainActor () -> Bool) async throws {
        for _ in 0..<10_000 where !reached() { await Task.yield() }
        try #require(reached())
    }

    private func make(owner: (any DeviceOwnerAuthenticating)?) async throws -> Harness {
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
        let ledger = PersonInputLedger(check: { event in
            event.cgEvent?.getIntegerValueField(.eventSourceUnixProcessID) == 0
        })
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
    /// owner here, so it fails closed), and the same posted click turns both off.
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

    /// The person's own click (source pid 0, HID state) asks too: the source fields can be forged, so they
    /// never skip the confirm. A cancel leaves it off; a success turns it on.
    @Test func thePersonsOwnClickAsksAndOnlyASuccessTurnsItOn() async throws {
        let owner = FakeOwner()
        let h = try await make(owner: owner)
        defer { h.cleanUp() }
        for op in Switch.allCases {
            owner.answer = false
            #expect(try await h.refused(op, on: true, h.click(0)), "a cancelled confirm turned \(op) on")
            #expect(owner.reasons.last == op.reason)
            owner.answer = true
            #expect(try await !h.refused(op, on: true, h.click(0)))
            #expect(h.recorder.sets.last == "\(op.set) true")
        }
        #expect(owner.reasons == [Switch.fullAccess.reason, Switch.fullAccess.reason, Switch.vmHost.reason, Switch.vmHost.reason])
        #expect(Switch.fullAccess.reason != Switch.vmHost.reason)
    }

    /// A posted click is not person input, so it never reaches the confirm; turning off still takes any input.
    @Test func anyOtherClickIsRefusedBeforeConfirmButOffStillWorks() async throws {
        let owner = FakeOwner()
        let h = try await make(owner: owner)
        defer { h.cleanUp() }
        for op in Switch.allCases {
            #expect(try await h.refused(op, on: true, h.posted()))
            #expect(!h.recorder.sets.contains("\(op.set) true"))
        }
        for op in Switch.allCases { #expect(try await !h.refused(op, on: false, h.posted())) }
        #expect(owner.reasons.isEmpty, "posted input never asks")
    }

    /// The click is spent before the confirm: a cancelled confirm's click, sent again, asks nothing and
    /// turns nothing on, and a page script with no click never reaches the confirm.
    @Test func aCancelledConfirmsClickIsSpentAndScriptNeverAsks() async throws {
        let owner = FakeOwner()
        let h = try await make(owner: owner)
        defer { h.cleanUp() }
        let click = try h.click(0)
        #expect(try await h.refused(.vmHost, on: true, click))
        owner.answer = true
        #expect(try await h.refused(.vmHost, on: true, click), "the same click again")
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

    /// One person gesture cannot be replayed across the other Settings switches that widen access,
    /// including the joined-screen/control consent handled by the same page provider.
    @Test func oneGestureCannotTurnOnJoinConsentAfterAWideningSwitch() async throws {
        let h = try await make(owner: AlwaysConfirms())
        defer { h.cleanUp() }
        h.page.setJoinConsent = { surface, on in h.recorder.sets.append("join \(surface) \(on)"); return nil }
        let click = try h.click(0)
        h.ledger.record(click)
        _ = try await h.page.call(Switch.fullAccess.rawValue,
                                   params: ["id": "m1", "on": true],
                                   context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true,
                                                             gestureEvent: click.timestamp))
        do {
            _ = try await h.page.call("cmux.settings.devices.join_consent",
                                      params: ["surface": "screen", "on": true],
                                      context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true,
                                                                gestureEvent: click.timestamp))
            Issue.record("one person gesture enabled two widening settings")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(h.recorder.sets == ["device true"])
    }

    /// Join consent uses the same cancellation-safe permit as the widening switches: a request canceled
    /// while an earlier write is in flight never reaches the host after that earlier write lands.
    @Test(.timeLimit(.minutes(1))) func aCancelledJoinConsentNeverReachesTheHost() async throws {
        let h = try await make(owner: nil)
        defer { h.cleanUp() }
        let landing = Landing()
        defer { landing.release() }
        var calls = 0
        h.page.setJoinConsent = { surface, on in
            calls += 1
            if calls == 1 { return await landing.write("join \(surface)", on, h.recorder) }
            h.recorder.sets.append("join \(surface) \(on)")
            return nil
        }
        let firstEvent = try h.click(0)
        h.ledger.record(firstEvent)
        let first = Task {
            try await h.page.call("cmux.settings.devices.join_consent",
                                  params: ["surface": "screen", "on": true],
                                  context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true,
                                                            gestureEvent: firstEvent.timestamp))
        }
        try #require(await landing.arrived(first))

        let secondEvent = try h.click(0)
        h.ledger.record(secondEvent)
        let second = Task {
            try await h.page.call("cmux.settings.devices.join_consent",
                                  params: ["surface": "screen", "on": true],
                                  context: PageCallContext(page: PageDescriptor.settings.id, userGesture: true,
                                                            gestureEvent: secondEvent.timestamp))
        }
        second.cancel()
        landing.land()
        _ = try await first.value
        do {
            _ = try await second.value
            Issue.record("a canceled join-consent write reached the host")
        } catch is CancellationError {
            // Expected: the request was canceled before its queued permit could be claimed.
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(h.recorder.sets == ["join screen true"])
    }

    /// One confirm at a time: while one is up, a second click is refused without a second prompt (an agent
    /// cannot stack prompts behind the person's), and the first still turns on only its switch.
    @Test(.timeLimit(.minutes(1))) func aSecondAskWhileOneIsUpIsRefused() async throws {
        let owner = FakeOwner()
        owner.hold = true
        let h = try await make(owner: owner)
        defer {
            owner.resume(false)
            h.cleanUp()
        }
        let asking = try h.heldOn(.fullAccess, pid: 0)
        #expect(await owner.held(asking))
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
            let asking = try h.heldOn(op, pid: 0)
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
        let asking = try h.heldOn(.vmHost, pid: 0)
        #expect(await owner.held(asking))
        #expect(try await !h.refused(.fullAccess, on: false, h.posted()))
        owner.resume(true)
        _ = try await asking.value
        #expect(h.recorder.sets == ["device false", "vm false", "device false", "vm true"])
    }

    /// Writes for one switch on one machine land in the order they were asked: an off asked while an on's
    /// write is in flight lands after it, and an on asked after that off lands last. An on still queued
    /// when an off is asked is dropped.
    @Test(.timeLimit(.minutes(1))) func writesLandInTheOrderAskedAndAnOffDropsQueuedOns() async throws {
        let h = try await make(owner: AlwaysConfirms())
        let landing = Landing(), recorder = h.recorder
        var requests: [Task<JSONValue, any Error>] = []
        defer {
            landing.release()
            for request in requests { request.cancel() }
            h.cleanUp()
        }
        h.page.setDeviceFullAccess = { _, on in await landing.write("device", on, recorder) }
        h.page.setMachineVmHost = { _, on in await landing.write("vm", on, recorder) }
        for op in Switch.allCases {
            // on, then off while the on is in flight, then on again: on, off, on.
            let key = op.key("m1"), offs = h.page.wideningGate.offs[key, default: 0]
            let first = try h.heldOn(op, pid: 0)
            requests.append(first)
            try #require(await landing.arrived(first))
            let off = Task { [h] in try await h.refused(op, on: false, h.posted()) }
            try await Self.until { h.page.wideningGate.offs[key, default: 0] == offs + 1 }
            let second = try h.heldOn(op, pid: 0)
            requests.append(second)
            let afterOff = h.page.wideningGate.writes[key]
            try await Self.until { h.page.wideningGate.writes[key] != afterOff }
            landing.land()
            _ = try await first.value
            #expect(try await !off.value)
            try #require(await landing.arrived(second))
            landing.land()
            _ = try await second.value
        }
        #expect(h.recorder.sets == ["device true", "device false", "device true", "vm true", "vm false", "vm true"])
        // on in flight, a second on queued, then an off: the queued on is dropped and off lands last.
        let key = Switch.fullAccess.key("m1"), offs = h.page.wideningGate.offs[key, default: 0]
        let first = try h.heldOn(.fullAccess, pid: 0)
        requests.append(first)
        try #require(await landing.arrived(first))
        let tail = h.page.wideningGate.writes[key]
        let queued = try h.heldOn(.fullAccess, pid: 0)
        requests.append(queued)
        try await Self.until { h.page.wideningGate.writes[key] != tail }
        let off = Task { [h] in try await h.refused(.fullAccess, on: false, h.posted()) }
        try await Self.until { h.page.wideningGate.offs[key, default: 0] == offs + 1 }
        landing.land()
        _ = try await first.value
        do {
            _ = try await queued.value
            Issue.record("an on queued before an off was written")
        } catch let error as PageError {
            #expect(error.code == PageNativeOp.userOnlyCode)
        }
        #expect(try await !off.value)
        #expect(h.recorder.sets.suffix(2) == ["device true", "device false"])
    }
}
