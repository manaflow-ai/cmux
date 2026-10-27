import CmuxNextCompat
import CoreGraphics
import Foundation
import Testing
@testable import CmuxNextPhone

/// Records what the iOS backend sends to the simulator's HID service.
final class FakeSimulatorHID: SimulatorHIDSending {
    enum Sent: Equatable {
        case touches([PhoneTouch])
        case keys([PhoneKeyStroke])
        case button(page: UInt32, usage: UInt32)
        case softwareKeyboard
    }

    private let state = Mutex<[Sent]>([])
    let size: CGSize
    init(screenPoints: CGSize = CGSize(width: 400, height: 800)) { size = screenPoints }
    var sent: [Sent] { state.withLock { $0 } }

    func screenSize(of udid: String) async throws -> CGSize { size }
    func send(touches: [PhoneTouch], to udid: String) async throws { state.withLock { $0.append(.touches(touches)) } }
    func send(keys: [PhoneKeyStroke], to udid: String) async throws { state.withLock { $0.append(.keys(keys)) } }
    func press(page: UInt32, usage: UInt32, on udid: String) async throws {
        state.withLock { $0.append(.button(page: page, usage: usage)) }
    }
    func toggleSoftwareKeyboard(on udid: String) async throws { state.withLock { $0.append(.softwareKeyboard) } }
}

@Suite struct SimulatorLiveInputTests {
    let sim = PhoneDeviceID(mode: .simulator, raw: "SIM-1")

    @Test func aTapIsADownAndUpAtTheNormalizedPoint() async throws {
        let hid = FakeSimulatorHID()
        try await XcodePhoneBackend(runner: FakePhoneRunner(), hid: hid).send(.tap(PhonePoint(x: 100, y: 200)), to: sim)
        #expect(hid.sent == [.touches([
            PhoneTouch(phase: .began, x: 0.25, y: 0.25, offset: .zero),
            PhoneTouch(phase: .ended, x: 0.25, y: 0.25, offset: .milliseconds(50)),
        ])])
    }

    @Test func aSwipeMovesInEvenStepsOverItsDuration() async throws {
        let hid = FakeSimulatorHID()
        try await XcodePhoneBackend(runner: FakePhoneRunner(), hid: hid)
            .send(.swipe(from: PhonePoint(x: 200, y: 700), to: PhonePoint(x: 200, y: 100), seconds: 0.2), to: sim)
        guard case .touches(let touches) = try #require(hid.sent.first) else { Issue.record("no touches"); return }
        #expect(touches.first?.phase == .began)
        #expect(touches.last == PhoneTouch(phase: .ended, x: 0.5, y: 0.125, offset: .milliseconds(200)))
        #expect(touches.dropFirst().dropLast().allSatisfy { $0.phase == .moved })
        // Offsets only grow, one step per 16 ms frame at most.
        #expect(zip(touches, touches.dropFirst()).allSatisfy { $0.offset < $1.offset })
        #expect(touches.count >= 12)
    }

    @Test func pointsOutsideTheScreenAreRefused() async {
        let backend = XcodePhoneBackend(runner: FakePhoneRunner(), hid: FakeSimulatorHID())
        await #expect(throws: PhoneError.outsideScreen) {
            try await backend.send(.tap(PhonePoint(x: 500, y: 10)), to: sim)
        }
    }

    /// The backend checks a swipe time itself (callers other than PhoneService reach it): a time no gesture has is
    /// a typed error, not a trap in the 16 ms step count (p10-stability-093 fixer; before, seconds=1e300 trapped).
    @Test func aSwipeTimeNoGestureHasIsRefused() async {
        let hid = FakeSimulatorHID()
        let backend = XcodePhoneBackend(runner: FakePhoneRunner(), hid: hid)
        let start = PhonePoint(x: 200, y: 700), end = PhonePoint(x: 200, y: 100)
        for seconds in [1e300, .infinity, PhoneInput.longestSwipe * 2] {
            await #expect(throws: PhoneError.outOfRange(what: "the swipe's seconds")) {
                try await backend.send(.swipe(from: start, to: end, seconds: seconds), to: sim)
            }
        }
        await #expect(throws: PhoneError.outsideScreen) { try await backend.send(.tap(PhonePoint(x: 1e300, y: 0)), to: sim) }
        let gesture = PhoneGesture(screen: PhonePoint(x: 400, y: 800))
        #expect(throws: PhoneError.outOfRange(what: "the swipe's seconds")) {
            _ = try gesture.swipe(from: start, to: end, seconds: 1e300)
        }
        #expect(hid.sent.isEmpty)
    }

    @Test func typedASCIIBecomesHIDKeyStrokesWithShift() async throws {
        let hid = FakeSimulatorHID()
        try await XcodePhoneBackend(runner: FakePhoneRunner(), hid: hid).send(.text("aB1!\n"), to: sim)
        #expect(hid.sent == [.keys([
            PhoneKeyStroke(usage: 0x04, shift: false),
            PhoneKeyStroke(usage: 0x05, shift: true),
            PhoneKeyStroke(usage: 0x1E, shift: false),
            PhoneKeyStroke(usage: 0x1E, shift: true),
            PhoneKeyStroke(usage: 0x28, shift: false),
        ])])
    }

    @Test func textAKeyboardCannotTypeIsPastedThenCommandV() async throws {
        let hid = FakeSimulatorHID()
        let runner = FakePhoneRunner()
        try await XcodePhoneBackend(runner: runner, hid: hid).send(.text("héllo 日本"), to: sim)
        #expect(runner.runs == [["simctl", "pbcopy", "SIM-1"]])
        #expect(runner.stdins == [Data("héllo 日本".utf8)])
        #expect(hid.sent == [.keys([PhoneKeyStroke(usage: 0x19, shift: false, command: true)])])
    }

    @Test(arguments: [
        (PhoneButton.home, UInt32(0x0C), UInt32(0x40)), (.lock, 0x0C, 0x30), (.siri, 0x0C, 0xCF),
        (.volumeUp, 0x0C, 0xE9), (.volumeDown, 0x0C, 0xEA),
    ])
    func hardwareButtonsAreConsumerUsages(button: PhoneButton, page: UInt32, usage: UInt32) async throws {
        let hid = FakeSimulatorHID()
        try await XcodePhoneBackend(runner: FakePhoneRunner(), hid: hid).send(.button(button), to: sim)
        #expect(hid.sent == [.button(page: page, usage: usage)])
    }

    @Test func androidOnlyButtonsAreRefusedOnIOS() async {
        let backend = XcodePhoneBackend(runner: FakePhoneRunner(), hid: FakeSimulatorHID())
        await #expect(throws: PhoneError.unsupported(mode: .simulator, what: "the back button")) {
            try await backend.send(.button(.back), to: sim)
        }
    }

    @Test func withHIDTheSimulatorOffersTouchKeysAndButtons() {
        let device = PhoneDevice(id: sim, name: "iPhone", model: "iPhone 17", osVersion: "iOS 26.5", state: .ready)
        let live = XcodePhoneBackend(runner: FakePhoneRunner(), hid: FakeSimulatorHID()).capabilities(for: device)
        #expect(live.isSuperset(of: [.touch, .keyboard, .buttons, .liveScreen]))
        let still = XcodePhoneBackend(runner: FakePhoneRunner()).capabilities(for: device)
        #expect(still.isDisjoint(with: [.touch, .keyboard, .buttons, .liveScreen]))
    }

    @Test func aClickInTheTabMapsThroughTheAspectFitScreen() {
        // A 400x800 pt phone drawn into a 300x300 view: 150 wide, centered.
        let map = PhoneScreenMapping(screen: CGSize(width: 400, height: 800), view: CGSize(width: 300, height: 300))
        #expect(map.drawnRect == CGRect(x: 75, y: 0, width: 150, height: 300))
        // AppKit points are bottom-left; the top-left of the screen is at y = 300.
        #expect(map.normalized(viewPoint: CGPoint(x: 75, y: 300)) == CGPoint(x: 0, y: 0))
        #expect(map.normalized(viewPoint: CGPoint(x: 150, y: 150)) == CGPoint(x: 0.5, y: 0.5))
        #expect(map.normalized(viewPoint: CGPoint(x: 10, y: 150)) == nil)
        #expect(map.devicePoint(viewPoint: CGPoint(x: 150, y: 75)) == PhonePoint(x: 200, y: 600))
    }

    @Test func macKeysMapToHIDUsages() {
        #expect(PhoneKeyboard().usage(forMacKeyCode: 36) == 0x28) // Return
        #expect(PhoneKeyboard().usage(forMacKeyCode: 51) == 0x2A) // Delete
        #expect(PhoneKeyboard().usage(forMacKeyCode: 123) == 0x50) // Left arrow
        #expect(PhoneKeyboard().usage(forMacKeyCode: 0) == 0x04) // a
        #expect(PhoneKeyboard().usage(forMacKeyCode: 9999) == nil)
    }
}
