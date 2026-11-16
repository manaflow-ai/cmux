import CmuxNextControl
import Foundation
import Testing

/// Each launch of every build (release and NIGHTLY too) leaves one record of its launch marks in a file of the last
/// 50 launches, which `cmux app launch-times` reads (CMUX-571): the marks themselves live only in memory and
/// `debug.timings` answers only in a debug build.
@Suite struct LaunchTimesFileTests {
    static let marks: [String: Double] = [
        "main_start": 41.25, "first_window_frame_committed": 512.04, "home.first_page": 830.66,
        "reveal.home": 830.7, "dfl.menu": 200,
    ]

    static func temporaryFile(capacity: Int = LaunchTimesFile.capacity) -> LaunchTimesFile {
        LaunchTimesFile(url: FileManager.default.temporaryDirectory
            .appending(path: "launch-times-\(UUID().uuidString)/launch-times.jsonl"), capacity: capacity)
    }

    static func record(build: String = "200", marks: [String: Double] = marks, prewarmed: Bool = false) -> LaunchTimesRecord {
        LaunchTimesRecord(marks: marks, startedAt: Date(timeIntervalSince1970: 1_800_000_000), version: "1.0.0",
                          build: build, commit: "31583607", prewarmed: prewarmed)
    }

    @Test func aRecordCarriesTheLaunchesTimes() {
        let record = Self.record(prewarmed: true)
        #expect(record.preMainMs == 41.3)
        #expect(record.firstWindowFrameMs == 512)
        #expect(record.mainMs == 470.8, "main to the first frame")
        #expect(record.homeFirstPageMs == 830.7)
        #expect(record.homeRevealedBy == "mark")
        #expect(record.prewarmed)
        #expect(record.version == "1.0.0" && record.build == "200" && record.commit == "31583607")
        #expect(record.startedAt == "2027-01-15T08:00:00Z")
        var deadline = Self.marks
        deadline["reveal.home.by_deadline"] = 1700
        deadline["home.first_page"] = nil
        let byDeadline = Self.record(marks: deadline)
        #expect(byDeadline.homeRevealedBy == "deadline")
        #expect(byDeadline.homeFirstPageMs == nil)
    }

    /// Home shows from its saved state before the Chief's first page (launch piece 3): the record is
    /// written at `reveal.home`, so its Home time is the saved page's, not a nil for a page still to come.
    @Test func homesTimeIsItsSavedPageWhenItShowedFirst() {
        var marks = Self.marks
        marks["home.first_page"] = nil
        marks["home.saved_page_shown"] = 640.04
        marks["reveal.home"] = 640.1
        let record = Self.record(marks: marks)
        #expect(record.homeFirstPageMs == 640)
        #expect(record.homeRevealedBy == "mark")
    }

    @Test func aLaunchWritesOneLineThatReadsBack() throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        let line = try file.append(Self.record(prewarmed: true))
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text == line + "\n", "one line per launch")
        let json = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(Set(json.keys) == ["started_at", "version", "build", "commit", "pre_main_ms", "main_ms", "first_window_frame_ms",
                                   "home_first_page_ms", "home_revealed_by", "prewarmed", "first_launch_of_build"])
        var expected = Self.record(prewarmed: true)
        expected.firstLaunchOfBuild = true
        #expect(file.records() == [expected])
    }

    @Test func onlyAnotherBuildsLaunchBeforeMakesTheFirstLaunchOfABuild() throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try file.append(Self.record(build: "199"))
        try file.append(Self.record(build: "200"))
        try file.append(Self.record(build: "200"))
        #expect(file.records().map(\.firstLaunchOfBuild) == [true, true, false])
    }

    @Test func theFileKeepsOnlyTheLastLaunches() throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        for build in 1...(LaunchTimesFile.capacity + 12) { try file.append(Self.record(build: "\(build)")) }
        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.split(separator: "\n").count == LaunchTimesFile.capacity)
        #expect(file.records().map(\.build) == ((13...(LaunchTimesFile.capacity + 12)).map { "\($0)" }), "the newest, oldest first")
    }

    /// A file that is not one this wrote (too large to be 50 records) is started over, never read whole.
    @Test func anOversizedFileIsStartedOver() throws {
        let file = Self.temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.url.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: UInt8(ascii: "x"), count: 300 * 1024).write(to: file.url)
        try file.append(Self.record())
        #expect(file.records().count == 1)
    }

    @Test func noTestProcessWritesThePersonsFile() {
        #expect(LaunchTimesFile.app(bundleID: "com.cmuxterm.app.nightly") == nil)
    }
}
