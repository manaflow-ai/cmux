import CmuxNextMetrics
import CmuxNextTrace
import Foundation
import Testing

/// The previous-launch fold (task 053): each earlier launch's file is its own section under that launch's own
/// profile, folded once, and a failed upload is retried at the next fold.
struct MetricsLaunchFoldTests {
    /// A launch file's contents as the fake store writes them: the source launch's id (a real store's header
    /// identity), the profile's version and the unsent samples.
    struct Launch: Codable, Sendable, Equatable, Identifiable {
        var id: String
        var version: String
        var samples: [Int64]
    }

    /// Reads `metrics-app-*.bin` files holding a JSON ``Launch`` (``MetricsLaunchFileReader`` reads the real layout).
    struct JSONLaunchReader: MetricsLaunchReading {
        func isLaunchFile(_ file: URL) -> Bool {
            file.lastPathComponent.hasPrefix("metrics-app-") && file.pathExtension == "bin"
        }

        func read(_ file: URL) throws(MetricsLaunchFoldError) -> Launch {
            guard let data = try? Data(contentsOf: file),
                  let launch = try? JSONDecoder().decode(Launch.self, from: data) else { throw MetricsLaunchFoldError.unreadable(file) }
            return launch
        }
    }

    struct UploadFailed: Error, Equatable {}

    private let folder: URL
    private let current: URL

    init() throws {
        folder = Self.temporaryFolder()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        current = folder.appending(path: "metrics-app-300.bin")
        try write(Launch(id: "launch-current", version: "1.3", samples: [9]), to: current)
    }

    /// By its real path: macOS lists `/var/folders/...` (a symlink) as `/private/var/folders/...`, and the
    /// fold's errors carry the URLs it listed, so a file the test names compares equal to the one it reports.
    private static func temporaryFolder() -> URL {
        FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appending(path: "metrics-fold-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    private func write(_ launch: Launch, to file: URL) throws {
        try JSONEncoder().encode(launch).write(to: file)
    }

    private func exists(_ file: URL) -> Bool { FileManager.default.fileExists(atPath: file.path) }

    private var fold: MetricsLaunchFold<JSONLaunchReader> {
        MetricsLaunchFold(directory: folder, current: current, reader: JSONLaunchReader())
    }

    @Test func aCrashedLaunchIsFoldedOnceUnderItsOwnVersion() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let crashed = folder.appending(path: "metrics-app-100.bin")
        try write(Launch(id: "launch-1.2", version: "1.2", samples: [3, 5]), to: crashed)

        var sent: [String: Launch] = [:]
        let first = await fold.run { (section: MetricsLaunchSection<Launch>) throws(UploadFailed) in
            sent[section.id] = section.contents
        }
        #expect(first.uploaded == ["launch-1.2"])
        #expect(first.errors.isEmpty && first.failed.isEmpty)
        #expect(sent == ["launch-1.2": Launch(id: "launch-1.2", version: "1.2", samples: [3, 5])],
                "the crashed launch's section took another launch's profile or samples")
        #expect(!exists(crashed))
        #expect(exists(current), "the fold deleted this launch's own file")

        let second = await fold.run { (_: MetricsLaunchSection<Launch>) throws(UploadFailed) in
            Issue.record("a launch was folded twice")
        }
        #expect(second.uploaded.isEmpty)
    }

    @Test func eachEarlierLaunchIsItsOwnSection() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(Launch(id: "launch-a", version: "1.1", samples: [1]), to: folder.appending(path: "metrics-app-100.bin"))
        try write(Launch(id: "launch-b", version: "1.2", samples: [2]), to: folder.appending(path: "metrics-app-200.bin"))

        let scan = try fold.sections()
        #expect(scan.sections.map(\.id) == ["launch-a", "launch-b"])
        #expect(scan.sections.map(\.contents.version) == ["1.1", "1.2"])
    }

    @Test func theSectionIDIsTheSourceLaunchNotTheFileName() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "metrics-app-100.bin")
        try write(Launch(id: "launch-before-reboot", version: "1.2", samples: [1]), to: file)
        let before = try fold.sections().sections.map(\.id)
        try write(Launch(id: "launch-after-reboot", version: "1.2", samples: [1]), to: file)
        let after = try fold.sections().sections.map(\.id)
        #expect(before == ["launch-before-reboot"] && after == ["launch-after-reboot"],
                "a later launch that reused the pid sent the earlier launch's section id")
    }

    @Test func readingIsIdempotentAndAFailedUploadIsRetriedOnce() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let earlier = folder.appending(path: "metrics-app-100.bin")
        try write(Launch(id: "launch-1.2", version: "1.2", samples: [7]), to: earlier)

        let read = try fold.sections().sections.map(\.contents)
        let readAgain = try fold.sections().sections.map(\.contents)
        #expect(read == [Launch(id: "launch-1.2", version: "1.2", samples: [7])] && readAgain == read)

        let failed = await fold.run { (_: MetricsLaunchSection<Launch>) throws(UploadFailed) in throw UploadFailed() }
        #expect(failed.failed.map { $0.id } == ["launch-1.2"])
        #expect(exists(earlier), "a failed upload deleted the file, so its samples are lost")

        var uploads = 0
        let retried = await fold.run { (_: MetricsLaunchSection<Launch>) throws(UploadFailed) in uploads += 1 }
        let again = await fold.run { (_: MetricsLaunchSection<Launch>) throws(UploadFailed) in uploads += 1 }
        #expect(retried.uploaded == ["launch-1.2"])
        #expect(again.uploaded.isEmpty)
        #expect(uploads == 1)
    }

    @Test func anUnreadableFileIsDeletedWithoutAnUpload() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let torn = folder.appending(path: "metrics-app-100.bin")
        try Data([0xFF, 0x00]).write(to: torn)

        let outcome = await fold.run { (_: MetricsLaunchSection<Launch>) throws(UploadFailed) in
            Issue.record("an unreadable file was uploaded")
        }
        #expect(outcome.errors == [.unreadable(torn)])
        #expect(!exists(torn))
    }

    @Test func theSpareFileAndOtherFilesAreNotLaunches() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(Launch(id: "spare", version: "1.3", samples: []), to: folder.appending(path: "metrics-spare.bin"))
        try write(Launch(id: "daemon", version: "1.3", samples: []), to: folder.appending(path: "metrics-daemon-55.bin"))

        #expect(try fold.sections().sections.isEmpty)
        #expect(exists(folder.appending(path: "metrics-spare.bin")))
    }

    @Test func aMissingFolderIsReported() async {
        let missing = folder.appending(path: "gone", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let outcome = await MetricsLaunchFold(directory: missing, current: current, reader: JSONLaunchReader())
            .run { (_: MetricsLaunchSection<Launch>) throws(UploadFailed) in }
        #expect(outcome.errors == [.unlisted(missing)])
    }

    // MARK: MetricsStore's files (task 052's layout)

    private static let day = MetricsProfile.Day(year: 2026, month: 10, day: 26)

    private static func profile(version: String, bootSession: UInt8) -> MetricsProfile {
        MetricsProfile(appVersion: version, buildNumber: "45", channel: "nightly", osVersion: "26.1.0",
                       hardwareClass: "Mac16,10", bootSessionUUID: Array(repeating: bootSession, count: 16), buildDay: day)
    }

    /// The `metrics-app-<pid>.bin` a launch of `version` leaves in `directory` after recording `samples` of
    /// main.turn. The store keeps the file mapped, as the launch did until it ended.
    private static func launchFile(in directory: URL, pid: UInt32, version: String, bootSession: UInt8,
                                   samples: [Int64]) throws -> MetricsStore {
        let runtime = TraceRuntime(role: .app)
        let store = MetricsStore(role: .app, profile: profile(version: version, bootSession: bootSession), pid: pid,
                                 catalog: [.mainTurn])
        #expect(store.attach(to: runtime))
        let metrics = Metrics(runtime: runtime)
        for sample in samples { metrics.record(.mainTurn, sample) }
        let path = try #require(store.adoptFile(directory: directory.path(percentEncoded: false)))
        #expect(path.hasSuffix("/" + MetricsStore.fileName(role: .app, pid: pid)))
        return store
    }

    @Test func aMetricsStoreFileIsFoldedOnceUnderItsOwnProfile() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let crashed = try Self.launchFile(in: folder, pid: 100, version: "1.2", bootSession: 1, samples: [3_000, 5_000])
        let fold = MetricsLaunchFold(directory: folder, current: folder.appending(path: MetricsStore.fileName(role: .app, pid: 300)),
                                     reader: MetricsLaunchFileReader(role: .app))

        var sent: [MetricsLaunchContents] = []
        let first = await fold.run { (section: MetricsLaunchSection<MetricsLaunchContents>) throws(UploadFailed) in
            sent.append(section.contents)
        }
        #expect(first.errors.isEmpty && first.failed.isEmpty)
        let section = try #require(sent.first)
        #expect(sent.count == 1)
        #expect(first.uploaded == [section.id])
        #expect(section.profile.appVersion == "1.2", "the crashed launch's section took another launch's profile")
        #expect(section.delta.histograms.map(\.name) == [HistogramID.mainTurn.name])
        #expect(section.delta.histograms.first?.count == 2)
        #expect(!exists(folder.appending(path: MetricsStore.fileName(role: .app, pid: 100))))

        let second = await fold.run { (_: MetricsLaunchSection<MetricsLaunchContents>) throws(UploadFailed) in
            Issue.record("a launch was folded twice")
        }
        #expect(second.uploaded.isEmpty)
        withExtendedLifetime(crashed) {}
    }

    @Test func twoLaunchesWithTheSamePidHaveDifferentSectionIDs() throws {
        let rebooted = Self.temporaryFolder(), wrapped = Self.temporaryFolder()
        defer {
            for directory in [folder, rebooted, wrapped] { try? FileManager.default.removeItem(at: directory) }
        }
        let first = try Self.launchFile(in: folder, pid: 100, version: "1.2", bootSession: 1, samples: [1_000])
        let afterReboot = try Self.launchFile(in: rebooted, pid: 100, version: "1.2", bootSession: 2, samples: [1_000])
        let afterWrap = try Self.launchFile(in: wrapped, pid: 100, version: "1.2", bootSession: 1, samples: [1_000])
        let reader = MetricsLaunchFileReader(role: .app)
        let name = MetricsStore.fileName(role: .app, pid: 100)

        let id = try reader.read(folder.appending(path: name)).id
        #expect(try reader.read(folder.appending(path: name)).id == id, "reading a file twice changed its section id")
        #expect(try reader.read(rebooted.appending(path: name)).id != id, "a launch after a reboot reused the section id")
        #expect(try reader.read(wrapped.appending(path: name)).id != id, "a launch after a pid wrap reused the section id")
        withExtendedLifetime((first, afterReboot, afterWrap)) {}
    }

    @Test func theFileReaderTakesOnlyItsRolesLaunchFiles() {
        defer { try? FileManager.default.removeItem(at: folder) }
        let reader = MetricsLaunchFileReader(role: .app)
        let spare = MetricsStore.spareName(role: .app)
        #expect(reader.isLaunchFile(folder.appending(path: MetricsStore.fileName(role: .app, pid: 4242))))
        #expect(!reader.isLaunchFile(folder.appending(path: spare)))
        #expect(!reader.isLaunchFile(folder.appending(path: spare + ".77.tmp")))
        #expect(!reader.isLaunchFile(folder.appending(path: MetricsStore.fileName(role: .daemon, pid: 4242))))
        #expect(!reader.isLaunchFile(folder.appending(path: "metrics-app-0100.bin")))
    }

    @Test func aRenamedSpareWithNoHeaderIsUnreadable() throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: MetricsStore.fileName(role: .app, pid: 100))
        try Data(count: 4_096).write(to: file)
        #expect(throws: MetricsLaunchFoldError.unreadable(file)) { try MetricsLaunchFileReader(role: .app).read(file) }
    }
}
