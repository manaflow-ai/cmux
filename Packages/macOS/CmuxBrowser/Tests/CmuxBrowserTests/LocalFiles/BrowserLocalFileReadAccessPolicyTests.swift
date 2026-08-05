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
    func fileOnlyCanonicalizationPreservesQueryAndFragment() throws {
        let fixture = try BrowserLocalFileTestFixture()
        defer { fixture.remove() }

        let target = fixture.targetDirectory.appendingPathComponent("report.html")
        let symlink = fixture.linkDirectory.appendingPathComponent("report.html")
        try "<!doctype html><title>report</title>".write(
            to: target,
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)

        var components = try #require(URLComponents(url: symlink, resolvingAgainstBaseURL: false))
        components.percentEncodedQuery = "case=one%20two"
        components.percentEncodedFragment = "section%202"
        let decoratedSymlink = try #require(components.url)

        let navigationURL = BrowserLocalFileReadAccessPolicy.fileOnly
            .resolvedNavigationURL(for: decoratedSymlink)
        let resolvedComponents = try #require(
            URLComponents(url: navigationURL, resolvingAgainstBaseURL: false)
        )

        #expect(navigationURL.path == target.standardizedFileURL.resolvingSymlinksInPath().path)
        #expect(resolvedComponents.percentEncodedQuery == "case=one%20two")
        #expect(resolvedComponents.percentEncodedFragment == "section%202")
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
