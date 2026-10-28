import CmuxNextCompat
import Foundation
import Testing
@testable import CmuxNextPhone

@Suite struct PhoneRecorderTests {
    let device = PhoneDevice(id: PhoneDeviceID(mode: .simulator, raw: "SIM-1"), name: "iPhone 18 Pro",
                             model: "iPhone 18 Pro", osVersion: "iOS 27.0", state: .ready)

    /// A clock the test moves by hand.
    final class Ticks: Sendable {
        private let value = Mutex(Duration.zero)
        func advance(_ by: Duration) { value.withLock { $0 += by } }
        var now: Duration { value.withLock { $0 } }
    }

    @Test func aRecordingKeepsVideoLogTimedInputsNotesAndPoster() async throws {
        let runner = FakePhoneRunner()
        let root = temporaryFolder()
        let ticks = Ticks()
        let recorder = PhoneRecorder(backend: XcodePhoneBackend(runner: runner), root: root,
                                     now: { Date(timeIntervalSince1970: 1_800_000_000) }, uptime: { ticks.now }, makeID: { "rec-1" })
        try await recorder.start(device)
        #expect(runner.started.map { $0.arguments.prefix(4) } == [["simctl", "io", "SIM-1", "recordVideo"], ["simctl", "spawn", "SIM-1", "log"]])
        ticks.advance(.milliseconds(1500))
        await recorder.note(.tap(PhonePoint(x: 100, y: 200)), on: device.id)
        await recorder.note(.tap(PhonePoint(x: 1, y: 1)), on: PhoneDeviceID(mode: .simulator, raw: "OTHER"))
        ticks.advance(.milliseconds(2250))
        await recorder.note(.text("hi"), on: device.id)
        ticks.advance(.seconds(1))

        let done = try await recorder.stop(notes: "Send button does nothing")
        #expect(runner.started.allSatisfy { $0.command.interrupted })
        #expect(done.duration == 4.75)
        #expect(done.events.map(\.at) == [1.5, 3.75])
        #expect(done.events.map(\.kind) == ["tap", "text"])
        #expect(done.video == "screen.mov")
        #expect(done.log == "device-log.ndjson")
        #expect(done.poster == "poster.png")

        let folder = root.appendingPathComponent("rec-1")
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: folder.path))
        #expect(names == ["screen.mov", "device-log.ndjson", "events.jsonl", "notes.md", "poster.png", "manifest.json"])
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8) == "Send button does nothing")
        #expect(try String(contentsOf: folder.appendingPathComponent("events.jsonl"), encoding: .utf8).split(separator: "\n").count == 2)
        let loaded = try PhoneRecorder.load(folder)
        #expect(loaded.events == done.events)
        #expect(loaded.folder == folder)
        #expect(await recorder.active == nil)
    }

    @Test func oneRecordingAtATime() async throws {
        let recorder = PhoneRecorder(backend: XcodePhoneBackend(runner: FakePhoneRunner()), root: temporaryFolder())
        try await recorder.start(device)
        await #expect(throws: PhoneError.alreadyRecording) { try await recorder.start(device) }
        _ = try await recorder.stop()
        await #expect(throws: PhoneError.notRecording) { try await recorder.stop() }
    }

    @Test func realDevicesRecordMp4WithoutALogStream() async throws {
        let runner = FakePhoneRunner()
        let phone = PhoneDevice(id: PhoneDeviceID(mode: .device, raw: "DEV-1"), name: "iPhone", model: "iPhone 16 Pro",
                                osVersion: "iOS 27.0", state: .ready)
        let recorder = PhoneRecorder(backend: XcodePhoneBackend(runner: runner), root: temporaryFolder(), makeID: { "rec-2" })
        try await recorder.start(phone)
        let done = try await recorder.stop()
        #expect(done.video == "screen.mp4")
        #expect(done.log == nil)
        #expect(runner.started.count == 1)
    }
}
