import CmuxNextMetrics
import Foundation
import Testing

/// The previous-launch fold (task 053): each earlier launch's file is its own section under that launch's own
/// profile, folded once, and a failed upload is retried at the next fold.
struct MetricsLaunchFoldTests {
    /// A launch file's contents as the fake store writes them: the profile's version and the unsent samples.
    struct Launch: Codable, Sendable, Equatable {
        var version: String
        var samples: [Int64]
    }

    /// Reads `metrics-app-*.bin` files holding a JSON ``Launch`` (task 052's store reads its mapped layout).
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
        folder = FileManager.default.temporaryDirectory.appending(path: "metrics-fold-\(UUID().uuidString)",
                                                                  directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        current = folder.appending(path: "metrics-app-300.bin")
        try write(Launch(version: "1.3", samples: [9]), to: current)
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
        try write(Launch(version: "1.2", samples: [3, 5]), to: crashed)

        var sent: [String: Launch] = [:]
        let first = await fold.run { (section: MetricsLaunchSection<Launch>) throws(UploadFailed) in
            sent[section.id] = section.contents
        }
        #expect(first.uploaded == ["metrics-app-100.bin"])
        #expect(first.errors.isEmpty && first.failed.isEmpty)
        #expect(sent == ["metrics-app-100.bin": Launch(version: "1.2", samples: [3, 5])],
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
        try write(Launch(version: "1.1", samples: [1]), to: folder.appending(path: "metrics-app-100.bin"))
        try write(Launch(version: "1.2", samples: [2]), to: folder.appending(path: "metrics-app-200.bin"))

        let scan = try fold.sections()
        #expect(scan.sections.map(\.id) == ["metrics-app-100.bin", "metrics-app-200.bin"])
        #expect(scan.sections.map(\.contents.version) == ["1.1", "1.2"])
    }

    @Test func readingIsIdempotentAndAFailedUploadIsRetriedOnce() async throws {
        defer { try? FileManager.default.removeItem(at: folder) }
        let earlier = folder.appending(path: "metrics-app-100.bin")
        try write(Launch(version: "1.2", samples: [7]), to: earlier)

        let read = try fold.sections().sections.map(\.contents)
        let readAgain = try fold.sections().sections.map(\.contents)
        #expect(read == [Launch(version: "1.2", samples: [7])] && readAgain == read)

        let failed = await fold.run { (_: MetricsLaunchSection<Launch>) throws(UploadFailed) in throw UploadFailed() }
        #expect(failed.failed.map { $0.id } == ["metrics-app-100.bin"])
        #expect(exists(earlier), "a failed upload deleted the file, so its samples are lost")

        var uploads = 0
        let retried = await fold.run { (_: MetricsLaunchSection<Launch>) throws(UploadFailed) in uploads += 1 }
        let again = await fold.run { (_: MetricsLaunchSection<Launch>) throws(UploadFailed) in uploads += 1 }
        #expect(retried.uploaded == ["metrics-app-100.bin"])
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
        try write(Launch(version: "1.3", samples: []), to: folder.appending(path: "metrics-spare.bin"))
        try write(Launch(version: "1.3", samples: []), to: folder.appending(path: "metrics-daemon-55.bin"))

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
}
