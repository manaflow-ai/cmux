@testable import CmuxNextUpdater
import CmuxUpdater
import CryptoKit
import Foundation
import Testing

/// The Channels card's Switch into a build this Mac did not keep: the DMG's app is kept only when
/// it is this app (bundle id), the build asked for, and signed by this app's team; and it is kept
/// even when it is older than every kept build (no prune). Before any of that, the DMG must carry
/// this app's EdDSA signature (``ArchiveSignature``), as Sparkle checks every update.
struct BuildSwitchDownloadTests {
    private static let bundleID = "com.cmuxterm.app.nightly.cmux-next"

    /// The bytes the "download" writes, and the key the feed signs them with.
    private nonisolated static let image = Data("cmux NEXT disk image".utf8)
    private static let key = Curve25519.Signing.PrivateKey()
    private static var publicKey: String { key.publicKey.rawRepresentation.base64EncodedString() }
    private static func signed(_ data: Data = image, length: Int? = image.count) throws -> ArchiveSignature {
        ArchiveSignature(edSignature: try key.signature(for: data).base64EncodedString(), length: length)
    }

    /// A disk image is a folder here: the "download" writes ``image``, the "mount" returns the folder.
    private struct Volume: AppChannelDownloading, DiskImageMounting {
        let folder: URL
        func download(from url: URL, to destination: URL, progress: @escaping @Sendable (Double?) -> Void) async throws {
            try BuildSwitchDownloadTests.image.write(to: destination)
        }
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

    private static func app(in folder: URL, build: String, bundleID: String = bundleID, commit: String? = nil) throws {
        let contents = folder.appending(path: "cmux NEXT.app/Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": bundleID, "CFBundleVersion": build, "CFBundleShortVersionString": "1.0.0-nightly.\(build)"]
        if let commit { info["CMUXCommit"] = commit }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appending(path: "Info.plist"))
    }

    private static func run(build: String, imageBuild: String, imageID: String = bundleID, team: String = "TEAM",
                            keptAlready: [String] = [], signature: ArchiveSignature? = nil,
                            publicEDKey: String? = publicKey, commit: String? = nil,
                            imageCommit: String? = nil) async throws -> (String?, [String]) {
        let root = FileManager.default.temporaryDirectory.appending(path: "build-switch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let volume = root.appending(path: "volume", directoryHint: .isDirectory)
        try app(in: volume, build: imageBuild, bundleID: imageID, commit: imageCommit)
        let store = KeptVersionStore(root: root.appending(path: "versions", directoryHint: .isDirectory), teamID: { _ in "TEAM" })
        for kept in keptAlready {
            let source = root.appending(path: "kept-\(kept)", directoryHint: .isDirectory)
            try app(in: source, build: kept)
            try store.keep(bundle: source.appending(path: "cmux NEXT.app"), build: kept, limit: keptAlready.count)
        }
        let download = BuildSwitchDownload(store: store, bundleIdentifier: bundleID, teamID: "TEAM", publicEDKey: publicEDKey, commit: commit,
                                           downloader: Volume(folder: volume), mounter: Volume(folder: volume),
                                           inspector: Inspector(team: team), temporaryDirectory: root)
        let failure = await download.keep(build: build, from: URL(string: "https://files-next.cmux.com/nightly-next/next/x.dmg")!,
                                          signature: try signature ?? signed())
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

    @Test func aDiskImageThisAppsKeyDidNotSignIsNeverOpened() async throws {
        let other = ArchiveSignature(edSignature: try Curve25519.Signing.PrivateKey().signature(for: Self.image).base64EncodedString(),
                                     length: Self.image.count)
        let (otherKey, keptA) = try await Self.run(build: "100", imageBuild: "100", signature: other)
        #expect(otherKey?.contains("EdDSA signature does not check") == true)
        #expect(keptA.isEmpty)
        let (otherBytes, keptB) = try await Self.run(build: "100", imageBuild: "100",
                                                     signature: Self.signed(Data("other bytes".utf8)))
        #expect(otherBytes?.contains("EdDSA signature does not check") == true)
        #expect(keptB.isEmpty)
        let (noLength, keptE) = try await Self.run(build: "100", imageBuild: "100", signature: Self.signed(length: nil))
        #expect(noLength?.contains("names no length") == true)
        #expect(keptE.isEmpty)
        let (shortened, keptC) = try await Self.run(build: "100", imageBuild: "100", signature: Self.signed(length: 3))
        #expect(shortened?.contains("feed item says 3") == true)
        #expect(keptC.isEmpty)
        let (noKey, keptD) = try await Self.run(build: "100", imageBuild: "100", publicEDKey: nil)
        #expect(noKey?.contains("no update signing key") == true)
        #expect(keptD.isEmpty)
    }

    /// `cmux app try <sha>` with a commit build (cmuxterm-hq docs/design/nightly-per-commit-builds.md):
    /// the app must name the commit asked for, so one commit's folder never hands over another's build.
    @Test func aCommitBuildIsKeptOnlyWhenItsAppNamesThatCommit() async throws {
        let commit = "0123456789abcdef0123456789abcdef01234567"
        let (short, keptA) = try await Self.run(build: "100", imageBuild: "100", commit: commit, imageCommit: "0123456789")
        #expect(short == nil)
        #expect(keptA == ["100"])
        let (other, keptB) = try await Self.run(build: "100", imageBuild: "100", commit: commit, imageCommit: "89abcdef01")
        #expect(other?.contains("holds commit 89abcdef01") == true)
        #expect(keptB.isEmpty)
        let (none, keptC) = try await Self.run(build: "100", imageBuild: "100", commit: commit)
        #expect(none?.contains("holds commit ?") == true)
        #expect(keptC.isEmpty)
        // A feed build is not asked for a commit.
        let (feed, keptD) = try await Self.run(build: "100", imageBuild: "100", imageCommit: "89abcdef01")
        #expect(feed == nil)
        #expect(keptD == ["100"])
    }

    @Test func aCommitBuildDownloadsFromItsCommitsFolderBesideTheFeed() {
        let folder = URL(string: "https://files-next.cmux.com/nightly-next/")!
        let commit = "0123456789abcdef0123456789abcdef01234567"
        #expect(UpdaterService.nightlyCommitDiskImageURL(build: "4447747433201", commit: commit, in: folder, architecture: .arm64)?
            .absoluteString == "https://files-next.cmux.com/nightly-next/commits/\(commit)/cmux-nightly-commit-macos-arm64-4447747433201.dmg")
        #expect(UpdaterService.nightlyCommitDiskImageURL(build: "1", commit: commit, in: folder, architecture: .x86_64) == nil)
        #expect(UpdaterService.nightlyCommitDiskImageURL(build: "1", commit: "0123456", in: folder, architecture: .arm64) == nil)
        #expect(UpdaterService.nightlyCommitDiskImageURL(build: "1", commit: commit.uppercased(), in: folder, architecture: .arm64) == nil)
        #expect(UpdaterService.nightlyCommitDiskImageURL(build: "1", commit: "../" + commit.dropFirst(3), in: folder, architecture: .arm64) == nil)
        #expect(UpdaterService.nightlyCommitDiskImageURL(build: "../1", commit: commit, in: folder, architecture: .arm64) == nil)
        #expect(UpdaterService.nightlyCommitDiskImageURL(build: "1", commit: commit, in: URL(string: "http://files-next.cmux.com/nightly-next/")!,
                                                         architecture: .arm64) == nil)
    }

    @Test func theSignatureFileBesideTheDiskImageIsReadByItsName() async throws {
        let dmg = URL(string: "https://files-next.cmux.com/nightly-next/next/cmux-nightly-next-macos-arm64-7.dmg")!
        #expect(ArchiveSignature.sidecar(for: dmg)?.absoluteString == dmg.absoluteString + ".signature.json")
        #expect(ArchiveSignature.sidecar(for: URL(string: "http://example.com/x.dmg")!) == nil)
        let body = Data(#"{"name":"cmux-nightly-next-macos-arm64-7.dmg","edSignature":"c2ln","length":12}"#.utf8)
        let read = await ArchiveSignature.published(for: dmg) { $0.lastPathComponent.hasSuffix(".dmg.signature.json") ? body : nil }
        #expect(read == ArchiveSignature(edSignature: "c2ln", length: 12))
        #expect(await ArchiveSignature.published(for: dmg) { _ in nil } == nil)
    }

    @Test func theFeedItemCarriesItsEnclosureSignature() throws {
        let feed = Data("""
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>7</sparkle:version>
        <enclosure url="https://files-next.cmux.com/nightly-next/next/x-7.dmg" length="12" sparkle:edSignature="c2ln"/>
        </item></channel></rss>
        """.utf8)
        let item = try #require(try AppcastParser.parse(feed).first)
        #expect(item.signature == ArchiveSignature(edSignature: "c2ln", length: 12))
    }
}
