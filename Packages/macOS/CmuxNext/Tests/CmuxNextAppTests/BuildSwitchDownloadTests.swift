@testable import CmuxNextUpdater
import CmuxUpdater
import Foundation
import Testing

/// The Channels card's Switch into a build this Mac did not keep: the DMG's app is kept only when
/// it is this app (bundle id), the build asked for, and signed by this app's team; and it is kept
/// even when it is older than every kept build (no prune).
struct BuildSwitchDownloadTests {
    private static let bundleID = "com.cmuxterm.app.nightly.cmux-next"

    /// A disk image is a folder here: the "download" writes nothing, the "mount" returns the folder.
    private struct Volume: AppChannelDownloading, DiskImageMounting {
        let folder: URL
        func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {}
        func attach(_ image: URL) async throws -> URL { folder }
        func detach(_ mountPoint: URL) async {}
    }

    private struct Inspector: AppSignatureInspecting {
        var team: String
        func inspect(appURL: URL, teamIdentifier: String) throws -> AppSignatureReport {
            let id = Bundle(url: appURL)?.bundleIdentifier
            return AppSignatureReport(bundleIdentifier: id, signingIdentifier: id, teamIdentifier: team,
                                      satisfiesDeveloperIDRequirement: true)
        }
    }

    private static func app(in folder: URL, build: String, bundleID: String = bundleID) throws {
        let contents = folder.appending(path: "cmux NEXT.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleVersion": build, "CFBundleShortVersionString": "1.0.0-nightly.\(build)"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
    }

    private static func run(build: String, imageBuild: String, imageID: String = bundleID, team: String = "TEAM",
                            keptAlready: [String] = []) async throws -> (String?, [String]) {
        let root = FileManager.default.temporaryDirectory.appending(path: "build-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let volume = root.appending(path: "volume", directoryHint: .isDirectory)
        try app(in: volume, build: imageBuild, bundleID: imageID)
        let store = KeptVersionStore(root: root.appending(path: "versions", directoryHint: .isDirectory), teamID: { _ in "TEAM" })
        for kept in keptAlready {
            let source = root.appending(path: "kept-\(kept)", directoryHint: .isDirectory)
            try app(in: source, build: kept)
            try store.keep(bundle: source.appending(path: "cmux NEXT.app"), build: kept, limit: keptAlready.count)
        }
        let download = BuildSwitchDownload(store: store, bundleIdentifier: bundleID, teamID: "TEAM", downloader: Volume(folder: volume),
                                           mounter: Volume(folder: volume), inspector: Inspector(team: team),
                                           temporaryDirectory: root)
        let failure = await download.keep(build: build, from: URL(string: "https://files-next.cmux.com/nightly-next/next/x.dmg")!)
        return (failure, store.list().map(\.build))
    }

    @Test func theBuildAskedForIsKeptEvenWhenOlderThanEveryKeptOne() async throws {
        let (failure, kept) = try await Self.run(build: "100", imageBuild: "100", keptAlready: ["300", "200"])
        #expect(failure == nil)
        #expect(kept == ["300", "200", "100"])
    }

    @Test func anotherBuildAnotherAppOrAnotherTeamIsNeverKept() async throws {
        let (otherBuild, keptA) = try await Self.run(build: "100", imageBuild: "101")
        #expect(otherBuild?.contains("build 101, not 100") == true)
        #expect(keptA.isEmpty)
        let (otherApp, keptB) = try await Self.run(build: "100", imageBuild: "100", imageID: "com.example.other")
        #expect(otherApp != nil)
        #expect(keptB.isEmpty)
        let (otherTeam, keptC) = try await Self.run(build: "100", imageBuild: "100", team: "OTHER")
        #expect(otherTeam != nil)
        #expect(keptC.isEmpty)
    }
}
