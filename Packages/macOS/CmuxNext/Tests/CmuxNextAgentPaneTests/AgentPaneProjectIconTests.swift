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
            home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("project-icon-\(UUID().uuidString)/home").path
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
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

    @MainActor
    @Test func aRemoteChatAsksThisMacForNoIcon() async {
        let model = AgentPaneModel(host: NoHost())
        model.remoteChat = true
        let reply = await model.respond(to: .projectIcon("/Users/me/site"))
        #expect((reply["value"] as? [String: Any])?["src"] == nil)
    }

    private actor NoHost: AgentPaneHostProviding {
        func handshake(sessionId: String?) async throws -> AgentPaneHandshake { throw AgentPaneHostError.daemonStopped }
    }
}
