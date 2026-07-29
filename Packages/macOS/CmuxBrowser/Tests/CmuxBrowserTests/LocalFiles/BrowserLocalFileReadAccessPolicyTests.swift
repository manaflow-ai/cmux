import Foundation
import Testing
@testable import CmuxBrowser

@Suite("Browser local-file read access")
struct BrowserLocalFileReadAccessPolicyTests {
    @Test
    func fileOnlyCanonicalizesSymlinkAndRestrictsReadAccessToTarget() throws {
        let fixture = try LocalFileFixture()
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

        #expect(navigationURL == target.standardizedFileURL)
        #expect(readAccessURL == target.standardizedFileURL)
    }

    @Test
    func fileOnlyRejectsDirectories() throws {
        let fixture = try LocalFileFixture()
        defer { fixture.remove() }

        #expect(
            BrowserLocalFileReadAccessPolicy.fileOnly.readAccessURL(
                for: fixture.targetDirectory
            ) == nil
        )
    }

    @Test
    func containingDirectoryPreservesDocumentURLAndGrantsParentAccess() throws {
        let fixture = try LocalFileFixture()
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
        let fixture = try LocalFileFixture()
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

private struct LocalFileFixture {
    let root: URL
    let targetDirectory: URL
    let linkDirectory: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmuxBrowserLocalFile-\(UUID().uuidString)", isDirectory: true)
        targetDirectory = root.appendingPathComponent("target", isDirectory: true)
        linkDirectory = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(
            at: targetDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: linkDirectory,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
