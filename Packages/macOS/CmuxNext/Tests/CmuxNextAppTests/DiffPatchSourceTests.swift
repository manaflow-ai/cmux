@testable import CmuxNextApp
import CmuxNextPages
import Foundation
import Testing

/// diff-host S4: `cmux-page://cmux.diff/__patch/<token>/<path>` serves only a
/// file the tab's own manifest lists, inside the session root (resolved
/// paths, compared by components), as `text/x-diff`.
@MainActor
@Suite(.serialized)
struct DiffPatchSourceTests {
    static func request(_ path: [String]) -> PageResourceRequest {
        PageResourceRequest(prefix: "__patch", path: path,
                            url: URL(string: "cmux-page://cmux.diff/__patch/" + path.joined(separator: "/"))!)
    }

    /// Adds `entry` to the grant's manifest.
    static func list(_ grant: DiffSessionGrant, _ entry: [String: Any]) throws {
        var manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: grant.manifestURL)) as? [String: Any] ?? [:]
        manifest["files"] = (manifest["files"] as? [[String: Any]] ?? []) + [entry]
        try JSONSerialization.data(withJSONObject: manifest).write(to: grant.manifestURL)
    }

    static func patchEntry(_ requestPath: String, _ file: URL, mime: String = "text/x-diff", remote: Any = NSNull()) -> [String: Any] {
        ["request_path": requestPath, "file_path": file.path, "mime_type": mime, "remote_url": remote]
    }

    @Test func servesAListedPatchWithTheSidecarMimeType() async throws {
        let world = try DiffPageProviderTests.world()
        let session = try await DiffPageProviderTests.open(world)
        let source = DiffPatchSource(ready: world.ready)
        let resource = try #require(await source.resource(for: Self.request([world.grant.token, "diff-session-\(session).patch"])))
        #expect(String(decoding: resource.data, as: UTF8.self) == "diff --git a/x b/x\n")
        #expect(resource.mimeType == "text/x-diff; charset=utf-8")
        await world.provider.close()
    }

    /// Two tabs share the root; neither reads the other's patches.
    @Test func aTabNeverServesAnotherTabsPatches() async throws {
        let first = try DiffPageProviderTests.world()
        let second = try DiffPageProviderTests.world(root: first.root)
        let mine = try await DiffPageProviderTests.open(first)
        let theirs = try await DiffPageProviderTests.open(second)
        let source = DiffPatchSource(ready: first.ready)
        #expect(await source.resource(for: Self.request([first.grant.token, "diff-session-\(mine).patch"])) != nil)
        // Their token, even with a path their manifest lists.
        #expect(await source.resource(for: Self.request([second.grant.token, "diff-session-\(theirs).patch"])) == nil)
        // My token, their file name: not in my manifest.
        #expect(await source.resource(for: Self.request([first.grant.token, "diff-session-\(theirs).patch"])) == nil)
        await first.provider.close()
        await second.provider.close()
    }

    @Test func refusesEntriesOutsideTheRootOrNotPatches() throws {
        let root = try DiffPageProviderTests.root()
        let grant = try DiffSessionGrant.create(root: root, repository: try DiffPageProviderTests.repository())
        defer { grant.remove() }
        let outsideDirectory = try URL(fileURLWithPath: DiffPageProviderTests.repository())
        let outside = outsideDirectory.appending(path: "secret.patch")
        try Data("secret".utf8).write(to: outside)
        // A sibling whose path starts with the root's path: only a component compare refuses it.
        let sibling = URL(fileURLWithPath: root.path + "x", isDirectory: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try Data("sibling".utf8).write(to: sibling.appending(path: "s.patch"))
        let link = root.appending(path: "link.patch")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let inside = root.appending(path: "inside.patch")
        try Data("inside".utf8).write(to: inside)

        try Self.list(grant, Self.patchEntry("/outside.patch", outside))
        try Self.list(grant, Self.patchEntry("/sibling.patch", sibling.appending(path: "s.patch")))
        try Self.list(grant, Self.patchEntry("/link.patch", link))
        try Self.list(grant, Self.patchEntry("/dots.patch", root.appending(path: "../" + outsideDirectory.lastPathComponent + "/secret.patch")))
        try Self.list(grant, Self.patchEntry("/remote.patch", inside, remote: "https://example.com/a.patch"))
        try Self.list(grant, Self.patchEntry("/inside.html", inside, mime: "text/html"))
        try Self.list(grant, Self.patchEntry("/inside.patch", inside))

        let resolver = DiffPatchResolver(root: root, token: grant.token)
        for path in ["outside.patch", "sibling.patch", "link.patch", "dots.patch", "remote.patch", "inside.html", "viewer.html"] {
            #expect(resolver.file(for: Self.request([grant.token, path])) == nil, "\(path)")
        }
        #expect(resolver.file(for: Self.request([grant.token, "inside.patch"]))?.lastPathComponent == "inside.patch")
        // Request paths with `.`/`..`, an empty token, another prefix.
        #expect(resolver.file(for: Self.request([grant.token, "..", "inside.patch"])) == nil)
        #expect(resolver.file(for: Self.request([grant.token, "", "inside.patch"])) == nil)
        #expect(resolver.file(for: Self.request(["", "inside.patch"])) == nil)
        #expect(resolver.file(for: PageResourceRequest(prefix: "__image", path: [grant.token, "inside.patch"],
                                                       url: URL(string: "cmux-page://cmux.diff/__image/x")!)) == nil)
    }

    @Test func aSymlinkedManifestIsRefused() throws {
        let root = try DiffPageProviderTests.root()
        let grant = try DiffSessionGrant.create(root: root, repository: try DiffPageProviderTests.repository())
        defer { grant.remove() }
        let inside = root.appending(path: "inside.patch")
        try Data("inside".utf8).write(to: inside)
        try Self.list(grant, Self.patchEntry("/inside.patch", inside))
        let elsewhere = URL(fileURLWithPath: try DiffPageProviderTests.repository()).appending(path: "manifest.json")
        try FileManager.default.moveItem(at: grant.manifestURL, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: grant.manifestURL, withDestinationURL: elsewhere)
        #expect(DiffPatchResolver(root: root, token: grant.token).file(for: Self.request([grant.token, "inside.patch"])) == nil)
    }

    @Test func theGrantFilesAreOwnerOnlyAndTheLeaseIsHeld() throws {
        let root = try DiffPageProviderTests.root()
        let grant = try DiffSessionGrant.create(root: root, repository: "/r")
        let attributes = try FileManager.default.attributesOfItem(atPath: root.path)
        #expect((attributes[.posixPermissions] as? Int) == 0o700)
        for name in [".manifest-\(grant.token).json", ".branch-session-\(grant.group).json"] {
            let mode = try FileManager.default.attributesOfItem(atPath: root.appending(path: name).path)[.posixPermissions] as? Int
            #expect(mode == 0o600, "\(name)")
        }
        #expect(DiffSessionRoot.leaseIsHeld(root: root, token: grant.token))
        // A sweep keeps a live grant and removes one whose lease is gone.
        DiffSessionRoot.sweep(root)
        #expect(FileManager.default.fileExists(atPath: grant.manifestURL.path))
        let session = try JSONSerialization.data(withJSONObject: ["token": String(repeating: "b", count: 48), "groupID": "tab-dead",
                                                                  "allowedRepoRoots": ["/r"]])
        try session.write(to: root.appending(path: ".branch-session-tab-dead.json"))
        DiffSessionRoot.sweep(root)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: ".branch-session-tab-dead.json").path))
        grant.remove()
        #expect(!DiffSessionRoot.leaseIsHeld(root: root, token: grant.token))
        #expect(!FileManager.default.fileExists(atPath: grant.manifestURL.path))
    }
}
