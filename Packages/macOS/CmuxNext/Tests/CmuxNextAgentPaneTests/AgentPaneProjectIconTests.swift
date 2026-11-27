import Foundation
import Testing
@testable import CmuxNextAgentPane

/// The project pickers' favicons (`project.icon {cwd}`): the host looks for a few well-known icon
/// files in a project folder and answers a small data URL, and never stats or reads anything in a
/// macOS privacy-protected folder (LAUNCH-NO-TCC-PROMPTS), even through a symlink.
@Suite(.serialized)
struct AgentPaneProjectIconTests {
    private static let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D])
    private static let svg = Data(#"<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg"/>"#.utf8)

    /// Every path the reader stats or reads.
    private nonisolated final class Touches: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []
        func add(_ path: String) { lock.withLock { paths.append(path) } }
        var all: [String] { lock.withLock { paths } }
    }

    private struct Fixture {
        let home: String
        let touches = Touches()

        init() throws {
            // `realpath`, as the reader resolves: `resolvingSymlinksInPath` drops `/private`.
            let made = FileManager.default.temporaryDirectory.appendingPathComponent("project-icon-\(UUID().uuidString)/home").path
            try FileManager.default.createDirectory(atPath: made, withIntermediateDirectories: true)
            guard let resolved = realpath(made, nil) else { throw CocoaError(.fileNoSuchFile) }
            defer { free(resolved) }
            home = String(cString: resolved)
        }

        func write(_ data: Data, _ relative: String) throws {
            let path = home + "/" + relative
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: path))
        }

        var reader: AgentPaneProjectIcon {
            let live = AgentPaneProjectIcon(home: home)
            let touches = touches
            var reader = live
            reader.stat = { touches.add($0); return live.stat($0) }
            reader.read = { touches.add($0); return live.read($0) }
            reader.readManifest = { touches.add($0); return live.readManifest($0) }
            return reader
        }

        func remove() { try? FileManager.default.removeItem(atPath: (home as NSString).deletingLastPathComponent) }
    }

    @Test func candidatesCoverTheRootAndTheUsualWebFolders() {
        let candidates = AgentPaneProjectIcon.candidates(in: "/p")
        for path in ["/p/favicon.ico", "/p/public/favicon.ico", "/p/static/favicon.png", "/p/app/icon.png",
                     "/p/src/app/favicon.ico", "/p/assets/favicon.svg", "/p/public/apple-touch-icon.png"] {
            #expect(candidates.contains(path), "\(path) is not a candidate")
        }
        // A vector or a large touch icon draws sharper in the 20pt tile than a 16px .ico.
        #expect(candidates.firstIndex(of: "/p/public/favicon.svg")! < candidates.firstIndex(of: "/p/favicon.ico")!)
    }

    /// The repository's own pick for cmux first; logos after every favicon.
    @Test func aChosenIconComesFirstAndLogosLast() {
        let candidates = AgentPaneProjectIcon.candidates(in: "/p")
        #expect(candidates.first == "/p/.cmux/icon.svg")
        #expect(candidates.contains("/p/assets/icon.png"))
        for logo in ["/p/logo.svg", "/p/logo.png", "/p/assets/logo.svg", "/p/assets/logo.png"] {
            #expect(candidates.firstIndex(of: logo)! > candidates.firstIndex(of: "/p/favicon.ico")!, "\(logo)")
        }
    }

    @Test func anXcodeAppIconIsItsLargestSmallEnoughPNG() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var small = Self.png
        small.append(Data(count: 100))
        var large = Self.png
        large.append(Data(count: 1000))
        var huge = Self.png
        huge.append(Data(count: AgentPaneProjectIcon.maximumBytes))
        let set = "code/App/App/Assets.xcassets/AppIcon.appiconset/"
        try fixture.write(small, set + "icon-16.png")
        try fixture.write(large, set + "icon-128.png")
        try fixture.write(huge, set + "icon-1024.png")
        try fixture.write(Data("{}".utf8), set + "Contents.json")
        #expect(fixture.reader.icon(in: fixture.home + "/code/App") == "data:image/png;base64," + large.base64EncodedString())
    }

    @Test func aProjectsFaviconIsAnsweredAsADataURL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.png, "code/site/public/favicon.png")
        let icon = fixture.reader.icon(in: fixture.home + "/code/site")
        #expect(icon == "data:image/png;base64," + Self.png.base64EncodedString())
    }

    @Test func theBestCandidateWinsAndAnOversizedOneIsSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.png, "code/site/favicon.ico")
        try fixture.write(Self.svg, "code/site/app/icon.svg")
        #expect(fixture.reader.icon(in: fixture.home + "/code/site")?.hasPrefix("data:image/svg+xml;base64,") == true)

        var big = Self.svg
        big.append(Data(count: AgentPaneProjectIcon.maximumBytes))
        try fixture.write(big, "code/site/app/icon.svg")
        #expect(fixture.reader.icon(in: fixture.home + "/code/site")?.hasPrefix("data:image/png;base64,") == true)
    }

    @Test func aFileThatIsNotAnImageIsNoIcon() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Data("<html>not found</html>".utf8), "code/site/public/favicon.png")
        #expect(fixture.reader.icon(in: fixture.home + "/code/site") == nil)
    }

    @Test func aProjectWithNoIconIsNil() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(atPath: fixture.home + "/code/empty", withIntermediateDirectories: true)
        #expect(fixture.reader.icon(in: fixture.home + "/code/empty") == nil)
    }

    @Test func aProtectedFolderIsNeverStatedOrRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.png, "Documents/site/favicon.png")
        try fixture.write(Self.png, "Desktop/app/public/favicon.png")
        let reader = fixture.reader
        #expect(reader.icon(in: fixture.home + "/Documents/site") == nil)
        #expect(reader.icon(in: fixture.home + "/desktop/app") == nil, "the Mac's disk ignores case")
        #expect(reader.icon(in: fixture.home) == nil, "the home folder is no project")
        #expect(reader.icon(in: "/") == nil)
        #expect(reader.icon(in: "relative/path") == nil)
        #expect(fixture.touches.all.isEmpty, "touched \(fixture.touches.all)")
    }

    @Test func aFaviconLinkedIntoAProtectedFolderIsNotRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.png, "Documents/secret.png")
        try FileManager.default.createDirectory(atPath: fixture.home + "/code/site", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.home + "/code/site/favicon.png",
                                                   withDestinationPath: fixture.home + "/Documents/secret.png")
        let reader = fixture.reader
        #expect(reader.icon(in: fixture.home + "/code/site") == nil)
        #expect(!fixture.touches.all.contains { $0.hasPrefix(fixture.home + "/Documents") || $0.hasSuffix("/code/site/favicon.png") },
                "touched \(fixture.touches.all)")
    }

    /// The Mac's disk matches names more loosely than `lowercased()`: `Documentſ` (long s) and the
    /// data volume's own spelling of the home folder both reach Documents.
    @Test func anotherSpellingOfAProtectedFolderIsNeverStatedOrRead() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.png, "Documents/site/favicon.png")
        let reader = fixture.reader
        #expect(reader.icon(in: fixture.home + "/Documentſ/site") == nil)
        #expect(reader.icon(in: "/System/Volumes/Data" + fixture.home + "/Documents/site") == nil)
        #expect(fixture.touches.all.isEmpty, "touched \(fixture.touches.all)")
    }

    @Test func aFaviconLinkedInsideTheProjectIsShown() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.svg, "code/mono/brand/favicon.svg")
        try FileManager.default.createDirectory(atPath: fixture.home + "/code/mono/web/public", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.home + "/code/mono/web/public/favicon.svg",
                                                   withDestinationPath: "../../brand/favicon.svg")
        #expect(fixture.reader.icon(in: fixture.home + "/code/mono/web") == "data:image/svg+xml;base64," + Self.svg.base64EncodedString())
    }

    /// A Git LFS pointer named favicon.png is text: the next candidate still counts.
    @Test func aCandidateThatIsNotAnImageLeavesTheNextOne() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Data("version https://git-lfs.github.com/spec/v1\n".utf8), "code/site/public/favicon.png")
        try fixture.write(Data([0x00, 0x00, 0x01, 0x00, 0x01, 0x00]), "code/site/favicon.ico")
        #expect(fixture.reader.icon(in: fixture.home + "/code/site")?.hasPrefix("data:image/x-icon;base64,") == true)
        let icons = AgentPaneProjectIcons(reader: fixture.reader)
        #expect(await icons.icon(for: fixture.home + "/code/site")?.hasPrefix("data:image/x-icon;base64,") == true)
        #expect(await icons.icon(for: fixture.home + "/code/site")?.hasPrefix("data:image/x-icon;base64,") == true)
    }

    @Test func anSVGWhoseFirstKilobyteEndsMidCharacterIsStillAnSVG() {
        var data = Data("<svg xmlns=\"http://www.w3.org/2000/svg\"><title>".utf8)
        data.append(Data(repeating: UInt8(ascii: "a"), count: 1023 - data.count))
        data.append(Data("é</title></svg>".utf8))
        #expect(AgentPaneProjectIcon.imageType(data) == "image/svg+xml")
    }

    @Test func theCacheRereadsOnlyAfterTheFileChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.png, "code/site/favicon.png")
        let path = fixture.home + "/code/site/favicon.png"
        let icons = AgentPaneProjectIcons(reader: fixture.reader)
        let first = await icons.icon(for: fixture.home + "/code/site")
        #expect(first?.hasPrefix("data:image/png;base64,") == true)
        #expect(await icons.icon(for: fixture.home + "/code/site") == first)
        #expect(fixture.touches.all.filter { $0 == path }.count == 3, "two stats and one read: \(fixture.touches.all)")

        try fixture.write(Self.svg, "code/site/favicon.png")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: path)
        // The type comes from the bytes, not the name.
        #expect(await icons.icon(for: fixture.home + "/code/site") == "data:image/svg+xml;base64," + Self.svg.base64EncodedString())
    }

    /// A clock the test moves by hand.
    private nonisolated final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { instant } }
        func advance(_ by: Duration) { lock.withLock { instant = instant.advanced(by: by) } }
    }

    /// A folder that is not on this Mac (a lane VM's `/home/cmux/...`) answers empty with no look for
    /// `missingLifetime`: the page asks again for every empty answer, and each look walked about 70 paths
    /// through the `/home` automounter (2026-10-30: opendirectoryd at 230-330 queries a second). A folder
    /// that is here is read on every ask, so an icon added to it shows on the next one.
    @Test func aFolderNotOnThisMacIsLookedForOncePerLifetime() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gone = fixture.home + "/code/elsewhere"
        let stats = Touches()
        let clock = Clock()
        let noAvatars = AgentPaneOwnerAvatars(folder: nil, fetch: { _ in nil })
        let icons = AgentPaneProjectIcons(reader: fixture.reader, avatars: noAvatars,
                                          isFolder: { stats.add($0); return AgentPaneProjectIcons.folderExists($0) },
                                          now: { clock.now })
        for _ in 0..<3 {
            let answer = await icons.answer(for: gone)
            #expect(answer.src == nil && answer.glyph == nil)
        }
        #expect(stats.all == [gone], "one existence check for three asks")
        #expect(fixture.touches.all.isEmpty, "no candidate is looked at in a missing folder")
        clock.advance(AgentPaneProjectIcons.missingLifetime)
        _ = await icons.answer(for: gone)
        #expect(stats.all == [gone, gone], "past the lifetime: checked again")

        // Here, but empty: every ask looks, so an icon added later shows on the next ask.
        let here = fixture.home + "/code/plain"
        try FileManager.default.createDirectory(atPath: here, withIntermediateDirectories: true)
        #expect(await icons.answer(for: here).src == nil)
        try fixture.write(Self.png, "code/plain/favicon.png")
        #expect(await icons.answer(for: here).src == "data:image/png;base64," + Self.png.base64EncodedString())
    }

    /// The same request from a chat on another machine is answered with no icon; from this Mac's
    /// chat, the real reader answers.
    @MainActor
    @Test func aRemoteChatAsksThisMacForNoIcon() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.png, "code/site/favicon.png")
        let folder = fixture.home + "/code/site"
        let remote = AgentPaneModel(host: NoHost())
        remote.remoteChat = true
        #expect((await remote.respond(to: .projectIcon(folder))["value"] as? [String: Any])?["src"] == nil)
        let local = AgentPaneModel(host: NoHost())
        #expect((await local.respond(to: .projectIcon(folder))["value"] as? [String: Any])?["src"] as? String
            == "data:image/png;base64," + Self.png.base64EncodedString())
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
