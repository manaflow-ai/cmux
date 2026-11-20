import CmuxNextDictation
import Foundation
import Testing

@Suite struct ChiefScreenJournalTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "chief-screen-\(UUID().uuidString)", directoryHint: .isDirectory)
    private let utc = TimeZone(identifier: "UTC") ?? .current

    private func frame(_ text: String) throws -> ChiefScreenFrame {
        let signature = try #require(VoiceRoomFrameSignature(pixels: [UInt8](repeating: 7, count: 640)))
        return ChiefScreenFrame(signature: signature, jpeg: Data("jpeg \(text)".utf8), text: text, app: "Xcode", window: "Build Failed")
    }

    private func names(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted()
    }

    @Test func aRememberedFrameWritesItsSourceAnInboxEntryAndTheCurrentScreen() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ChiefScreenJournal(directory: folder, timeZone: utc)
        await journal.beginSharing()
        let at = Date(timeIntervalSince1970: 1_793_382_125.25)  // 2026-10-30 17:42:05.250 UTC
        let seen = try #require(await journal.record(try frame("Build Failed: 2 errors"), at: at, remember: true))
        #expect(seen.day == "2026-10-30")
        #expect(seen.time == "17:42:05")
        #expect(seen.frame == folder.appending(path: "frames/2026-10-30/174205-250.jpg").path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: seen.frame)) == Data("jpeg Build Failed: 2 errors".utf8))
        #expect(names(journal.inbox) == ["1793382125250.json"])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = try decoder.decode(ChiefScreenObservation.self, from: Data(contentsOf: journal.inbox.appending(path: "1793382125250.json")))
        #expect(entry.text == "Build Failed: 2 errors")
        #expect(entry.app == "Xcode")
        #expect(entry.window == "Build Failed")
        #expect(FileManager.default.fileExists(atPath: journal.latestFrame.path))
        #expect(FileManager.default.fileExists(atPath: journal.latestEntry.path))
    }

    @Test func aFrameNotRememberedIsOnlyTheCurrentScreen() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ChiefScreenJournal(directory: folder, timeZone: utc)
        await journal.beginSharing()
        let seen = try #require(await journal.record(try frame("same text"), at: Date(timeIntervalSince1970: 1_793_382_125), remember: false))
        #expect(seen.frame == journal.latestFrame.path)
        #expect(names(journal.inbox).isEmpty)
        #expect(names(journal.frames).isEmpty)
    }

    @Test func endingDeletesTheCurrentScreenKeepsMemoryAndRefusesLaterWrites() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ChiefScreenJournal(directory: folder, timeZone: utc)
        #expect(await journal.record(try frame("before"), at: Date(), remember: true) == nil)
        await journal.beginSharing()
        _ = await journal.record(try frame("kept"), at: Date(timeIntervalSince1970: 1_793_382_125), remember: true)
        await journal.endSharing()
        #expect(!FileManager.default.fileExists(atPath: journal.latestFrame.path))
        #expect(!FileManager.default.fileExists(atPath: journal.latestEntry.path))
        #expect(names(journal.inbox).count == 1)
        #expect(await journal.record(try frame("after"), at: Date(), remember: true) == nil)
        #expect(names(journal.inbox).count == 1)
    }

    @Test func onlyTheNewestFramesStay() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ChiefScreenJournal(directory: folder, keepFrames: 2, timeZone: utc)
        await journal.beginSharing()
        for second in 0..<4 {
            _ = await journal.record(try frame("frame \(second)"), at: Date(timeIntervalSince1970: 1_793_382_120 + Double(second)), remember: true)
        }
        #expect(names(journal.frames.appending(path: "2026-10-30")) == ["174202-000.jpg", "174203-000.jpg"])
        #expect(names(journal.inbox) == ["1793382122000.json", "1793382123000.json"], "the inbox keeps the newest keepFrames entries too")
    }

    @Test func cmuxAndPasswordManagersAreNeverShared() {
        let exclusions = ChiefScreenShareExclusions(ownProcess: 42)
        #expect(exclusions.excludes(bundleID: nil, processID: 42))
        #expect(exclusions.excludes(bundleID: "com.cmuxterm.app.nightly", processID: 7))
        #expect(exclusions.excludes(bundleID: "com.1password.1password", processID: 7))
        #expect(exclusions.excludes(bundleID: "com.apple.Passwords", processID: 7))
        #expect(!exclusions.excludes(bundleID: "com.apple.Safari", processID: 7))
        #expect(!exclusions.excludes(bundleID: nil, processID: 7))
    }
}
