import AppKit
@testable import CmuxNextApp
import Foundation
import Testing

/// About cmux links to the bundled third-party notices (t3code credit, cx-1785).
struct AboutPanelCreditsTests {
    private func bundle(withNotices: Bool) throws -> (Bundle, URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("about-\(UUID().uuidString).bundle", isDirectory: true)
        let resources = root.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist = ["CFBundleIdentifier": "com.cmuxterm.test.about", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: root.appendingPathComponent("Contents/Info.plist"))
        let file = resources.appendingPathComponent("THIRD_PARTY_LICENSES.md")
        if withNotices { try "# Third-Party Licenses\n".write(to: file, atomically: true, encoding: .utf8) }
        return (try #require(Bundle(url: root)), root, file)
    }

    @Test func aBundleWithTheNoticesFileGivesCreditsThatLinkToIt() throws {
        let (bundle, root, file) = try bundle(withNotices: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let about = AboutPanelCredits(bundle: bundle)

        let url = try #require(about.licensesURL)
        #expect(url.resolvingSymlinksInPath().path == file.resolvingSymlinksInPath().path)
        let credits = try #require(about.credits)
        #expect(credits.string == AboutPanelCredits.title)
        #expect(credits.attribute(.link, at: 0, effectiveRange: nil) as? URL == url)
    }

    @Test func aBundleWithoutTheNoticesFileGivesNoCredits() throws {
        let (bundle, root, _) = try bundle(withNotices: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let about = AboutPanelCredits(bundle: bundle)
        #expect(about.licensesURL == nil)
        #expect(about.credits == nil)
    }
}
