import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser local-file read access")
struct BrowserLocalFileReadAccessPolicyTests {
    @Test
    func fileOnlyCanonicalizesSymlinkAndRestrictsReadAccessToTarget() throws {
        let fixture = try BrowserLocalFileTestFixture()
        defer { fixture.remove() }

        let target = fixture.targetDirectory.appendingPathComponent("diagram.html")
        let symlink = fixture.linkDirectory.appendingPathComponent("diagram.html")
        try "<!doctype html><title>diagram</title>".write(
            to: target,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let navigationURL = BrowserLocalFileReadAccessPolicy.fileOnly
            .resolvedNavigationURL(for: symlink)
        let readAccessURL = try #require(
            BrowserLocalFileReadAccessPolicy.fileOnly.readAccessURL(for: symlink)
        )

        let canonicalTarget = target.standardizedFileURL.resolvingSymlinksInPath()
        #expect(navigationURL == canonicalTarget)
        #expect(readAccessURL == canonicalTarget)
    }

    @Test
    func fileOnlyRejectsDirectories() throws {
        let fixture = try BrowserLocalFileTestFixture()
        defer { fixture.remove() }

        #expect(
            BrowserLocalFileReadAccessPolicy.fileOnly.readAccessURL(
                for: fixture.targetDirectory
            ) == nil
        )
    }

    @Test
    func containingDirectoryAcceptsDirectoryURL() throws {
        let fixture = try BrowserLocalFileTestFixture()
        defer { fixture.remove() }

        #expect(
            BrowserLocalFileReadAccessPolicy.containingDirectory.readAccessURL(
                for: fixture.targetDirectory
            ) == fixture.targetDirectory
        )
    }

    @Test
    func containingDirectoryUsesParentForMissingFile() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).html")

        #expect(
            BrowserLocalFileReadAccessPolicy.containingDirectory.readAccessURL(
                for: missing
            ) == missing.deletingLastPathComponent()
        )
    }

    @Test
    func rejectsHostOnlyFileURL() throws {
        let hostOnly = try #require(URL(string: "file://example.html"))

        #expect(
            BrowserLocalFileReadAccessPolicy.containingDirectory.readAccessURL(
                for: hostOnly
            ) == nil
        )
    }

    @Test
    func containingDirectoryPreservesDocumentURLAndGrantsParentAccess() throws {
        let fixture = try BrowserLocalFileTestFixture()
        defer { fixture.remove() }

        let target = fixture.targetDirectory.appendingPathComponent("diagram.html")
        let symlink = fixture.linkDirectory.appendingPathComponent("diagram.html")
        try "<!doctype html><title>diagram</title>".write(
            to: target,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        let navigationURL = BrowserLocalFileReadAccessPolicy.containingDirectory
            .resolvedNavigationURL(for: symlink)
        let readAccessURL = try #require(
            BrowserLocalFileReadAccessPolicy.containingDirectory.readAccessURL(for: symlink)
        )

        #expect(navigationURL == symlink)
        #expect(readAccessURL == fixture.linkDirectory)
    }

    @Test
    func identityUsesCanonicalFileTarget() throws {
        let fixture = try BrowserLocalFileTestFixture()
        defer { fixture.remove() }

        let target = fixture.targetDirectory.appendingPathComponent("diagram.html")
        let symlink = fixture.linkDirectory.appendingPathComponent("diagram.html")
        try "<!doctype html><title>diagram</title>".write(
            to: target,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        #expect(
            BrowserLocalFileIdentity(url: symlink) ==
                BrowserLocalFileIdentity(url: target)
        )
    }

    @Test
    func closedPanelSnapshotCarriesThePolicyValue() {
        let snapshot = ClosedBrowserPanelRestoreSnapshot(
            workspaceId: UUID(),
            url: URL(fileURLWithPath: "/tmp/diagram.html"),
            profileID: nil,
            localFileReadAccessPolicy: .fileOnly,
            originalPaneId: UUID(),
            originalTabIndex: 0,
            fallbackSplitOrientation: nil,
            fallbackSplitInsertFirst: false,
            fallbackAnchorPaneId: nil
        )

        #expect(snapshot.localFileReadAccessPolicy == .fileOnly)
    }
}
