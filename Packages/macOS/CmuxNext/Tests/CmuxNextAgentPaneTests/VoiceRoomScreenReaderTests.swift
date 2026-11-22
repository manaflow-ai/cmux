import CmuxNextComputerUse
import CmuxNextDictation
import CoreGraphics
import Darwin
import Foundation
import Testing

/// The Voice Room reads the screen only through the grant holder (the Screen Sharing helper): this
/// app never captures or asks macOS for Screen Recording, so macOS never lists cmux.
@Suite struct VoiceRoomScreenReaderTests {
    private final class FakeHolder: GrantHolding {
        var still: GrantHolderStill
        var stills: [(maxWidth: Int, pid: pid_t)] = []
        var screenRequests = 0

        init(_ still: GrantHolderStill) {
            self.still = still
        }

        func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) async -> GrantHolderAnswer { .unavailable }
        func screenStill(maxWidth: Int, excluding pid: pid_t) async -> GrantHolderStill {
            stills.append((maxWidth, pid))
            return still
        }
        func requestAccessibility() async {}
        func requestScreenRecording() async { screenRequests += 1 }
    }

    @Test func theStillComesFromTheHolderWithoutThisApp() async throws {
        let holder = FakeHolder(.pixels(GrantHolderPixels(width: 320, height: 200, rgba: Data(repeating: 128, count: 320 * 200 * 4))))
        let reader = VoiceRoomScreenReader(frames: nil, holder: holder)
        let sample = try await reader.read(changedSince: nil)
        #expect(sample != nil)
        #expect(holder.stills.count == 1)
        #expect(holder.stills.first?.maxWidth == 1440)
        // cmux's own windows are left out: the room page never reads itself back.
        #expect(holder.stills.first?.pid == getpid())
        // The same picture again is no change.
        #expect(try await reader.read(changedSince: sample?.signature) == nil)
    }

    @Test func withoutTheGrantMacOSIsAskedOnceForTheHelper() async {
        let holder = FakeHolder(.notGranted)
        let reader = VoiceRoomScreenReader(frames: nil, holder: holder)
        for _ in 0..<3 {
            await #expect(throws: VoiceRoomScreenReader.Unreadable(notGranted: true)) { try await reader.read(changedSince: nil) }
        }
        #expect(holder.screenRequests == 1)
    }

    @Test func withoutTheHelperNothingIsCaptured() async {
        let reader = VoiceRoomScreenReader(frames: nil, holder: nil)
        await #expect(throws: VoiceRoomScreenReader.Unreadable(notGranted: false)) { try await reader.read(changedSince: nil) }
    }
}
