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

    /// A project with no favicon answers its language from its marker files, a framework before
    /// its language's manifest; a folder with none answers nothing, and the page keeps the letters.
    @Test func aProjectWithoutAFaviconAnswersItsLanguage() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Data("// swift-tools-version:6.0\n".utf8), "code/kit/Package.swift")
        try fixture.write(Data("{}".utf8), "code/web/package.json")
        try fixture.write(Data("{}".utf8), "code/web/tsconfig.json")
        try fixture.write(Data("export default {}".utf8), "code/web/next.config.mjs")
        try fixture.write(Data("[package]".utf8), "code/tui/Cargo.toml")
        try fixture.write(Data("export default {}".utf8), "code/app/vite.config.mts")
        try fixture.write(Data("{}".utf8), "code/app/package.json")
        try fixture.write(Data("export default {}".utf8), "code/blog/astro.config.ts")
        try fixture.write(Data("export default {}".utf8), "code/blog/vite.config.js")
        try FileManager.default.createDirectory(atPath: fixture.home + "/code/notes", withIntermediateDirectories: true)
        let reader = fixture.reader
        #expect(reader.language(in: fixture.home + "/code/kit") == "swift")
        #expect(reader.language(in: fixture.home + "/code/web") == "nextjs")
        #expect(reader.language(in: fixture.home + "/code/tui/") == "rust")
        #expect(reader.language(in: fixture.home + "/code/app") == "vite")
        #expect(reader.language(in: fixture.home + "/code/blog") == "astro")
        #expect(reader.language(in: fixture.home + "/code/notes") == nil)
        // A folder named like a marker is not one.
        try FileManager.default.createDirectory(atPath: fixture.home + "/code/odd/go.mod", withIntermediateDirectories: true)
        #expect(reader.language(in: fixture.home + "/code/odd") == nil)
    }

    @Test func aMarkerInOrLinkedIntoAProtectedFolderIsNeverStated() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Data("[package]".utf8), "Documents/tui/Cargo.toml")
        try fixture.write(Data("{}".utf8), "Documents/secret.json")
        try FileManager.default.createDirectory(atPath: fixture.home + "/code/site", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: fixture.home + "/code/site/package.json",
                                                   withDestinationPath: fixture.home + "/Documents/secret.json")
        let reader = fixture.reader
        #expect(reader.language(in: fixture.home + "/Documents/tui") == nil)
        #expect(reader.language(in: fixture.home) == nil, "the home folder is no project")
        #expect(reader.language(in: fixture.home + "/code/site") == nil)
        #expect(!fixture.touches.all.contains { $0.hasPrefix(fixture.home + "/Documents") || $0.hasSuffix("/code/site/package.json") },
                "touched \(fixture.touches.all)")
    }

    /// The pane's request answers the favicon first, else the language.
    @MainActor
    @Test func theRequestAnswersTheLanguageWhenThereIsNoFavicon() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Data("module example.com/x\n".utf8), "code/svc/go.mod")
        let model = AgentPaneModel(host: NoHost())
        let value = await model.respond(to: .projectIcon(fixture.home + "/code/svc"))["value"] as? [String: Any]
        #expect(value?["src"] == nil)
        #expect(value?["language"] as? String == "go")
    }

    @Test func theRequestAnswersTheLanguageWithTheFavicon() async throws {
        // A favicon WebKit cannot draw falls back to the language's icon rather than the letters.
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.write(Self.png, "code/api/favicon.png")
        try fixture.write(Data("module example.com/api\n".utf8), "code/api/go.mod")
        let model = AgentPaneModel(host: NoHost())
        let value = await model.respond(to: .projectIcon(fixture.home + "/code/api"))["value"] as? [String: Any]
        #expect((value?["src"] as? String)?.hasPrefix("data:image/png;base64,") == true)
        #expect(value?["language"] as? String == "go")
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
