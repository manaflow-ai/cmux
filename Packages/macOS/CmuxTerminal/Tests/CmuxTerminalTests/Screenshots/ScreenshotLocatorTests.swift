import Darwin
import Foundation
import Testing

@testable import CmuxTerminal

@Suite("Screenshot locator")
struct ScreenshotLocatorTests {
    // MARK: - Folder

    @Test("an unset location falls back to ~/Desktop")
    func unsetLocationFallsBackToDesktop() throws {
        let home = try TemporaryHome()
        defer { home.remove() }

        let locator = home.locator()

        #expect(locator.screenshotDirectory().path == home.desktop.path)
    }

    @Test("a ~ location expands against the home directory")
    func tildeLocationExpands() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let shots = try home.makeDirectory("Pictures/Screenshots")

        let locator = home.locator(["location": "~/Pictures/Screenshots"])

        #expect(Self.resolved(locator.screenshotDirectory()) == Self.resolved(shots))
    }

    @Test("an absolute location is used as is")
    func absoluteLocationIsUsed() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let shots = try home.makeDirectory("Shots")

        let locator = home.locator(["location": " \(shots.path) "])

        #expect(Self.resolved(locator.screenshotDirectory()) == Self.resolved(shots))
    }

    @Test("relative, missing, or file locations fall back to ~/Desktop")
    func invalidLocationsFallBackToDesktop() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let file = try home.makeFile("not-a-folder.png", in: home.root, created: Date())

        for location in ["Pictures", "~/Missing", file.path, ""] {
            let locator = home.locator(["location": location])
            #expect(locator.screenshotDirectory().path == home.desktop.path, "location: \(location)")
        }
    }

    // MARK: - Newest screenshot

    @Test("picks the newest screenshot and ignores other files")
    func picksNewestScreenshotAndIgnoresOtherFiles() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try home.makeFile("Screenshot 2027-01-15 at 08.00.00.png", created: base)
        let expected = try home.makeFile("Screenshot 2027-01-15 at 09.00.00.png", created: base + 60)
        // Newer, but not screenshots: an unrelated image, a screen recording,
        // a hidden file, and a folder named like a screenshot.
        _ = try home.makeFile("holiday.png", created: base + 120)
        _ = try home.makeFile("Screen Recording 2027-01-15 at 09.05.00.mov", created: base + 180)
        _ = try home.makeFile(".Screenshot 2027-01-15 at 09.06.00.png", created: base + 240)
        _ = try home.makeDirectory("Desktop/Screenshot folder.png")

        let newest = home.locator().newestScreenshot()

        #expect(newest?.lastPathComponent == expected.lastPathComponent)
    }

    @Test("matches older names, date-less names, and a custom name prefix")
    func matchesScreenshotNameVariants() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let base = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try home.makeFile("Screen Shot 2019-05-01 at 10.00.00.png", created: base)
        #expect(home.locator().newestScreenshot()?.lastPathComponent == "Screen Shot 2019-05-01 at 10.00.00.png")

        _ = try home.makeFile("Screenshot.png", created: base + 60)
        #expect(home.locator().newestScreenshot()?.lastPathComponent == "Screenshot.png")

        _ = try home.makeFile("Capture 2027-01-15.png", created: base + 120)
        #expect(home.locator().newestScreenshot()?.lastPathComponent == "Screenshot.png")
        #expect(home.locator(["name": "Capture"]).newestScreenshot()?.lastPathComponent == "Capture 2027-01-15.png")
    }

    @Test("the screen-capture metadata marks a screenshot with a localized name")
    func screenCaptureMarkerQualifiesLocalizedName() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try home.makeFile("Screenshot 2027-01-15 at 08.00.00.png", created: base)
        let localized = try home.makeFile("Bildschirmfoto 2027-01-15 um 09.00.00.png", created: base + 60)
        try Self.markAsScreenCapture(localized)

        let locator = home.locator()

        #expect(locator.hasScreenCaptureMarker(localized))
        #expect(locator.newestScreenshot()?.lastPathComponent == localized.lastPathComponent)
    }

    @Test("the type preference adds its extension")
    func typePreferenceAddsExtension() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try home.makeFile("Screenshot 2027-01-15 at 08.00.00.png", created: base)
        _ = try home.makeFile("Screenshot 2027-01-15 at 09.00.00.pdf", created: base + 60)

        #expect(home.locator().newestScreenshot()?.pathExtension == "png")
        #expect(home.locator(["type": "pdf"]).newestScreenshot()?.pathExtension == "pdf")
    }

    @Test("reads the configured folder, not the Desktop")
    func readsConfiguredFolder() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let shots = try home.makeDirectory("Pictures/Screenshots")
        _ = try home.makeFile("Screenshot 2027-01-15 at 10.00.00.png", created: base + 60)
        let expected = try home.makeFile("Screenshot 2027-01-15 at 09.00.00.png", in: shots, created: base)

        let newest = home.locator(["location": "~/Pictures/Screenshots"]).newestScreenshot()

        #expect(newest?.lastPathComponent == expected.lastPathComponent)
        #expect(newest.map { Self.resolved($0.deletingLastPathComponent()) } == Self.resolved(shots))
    }

    @Test("returns nil without a screenshot or a readable folder")
    func returnsNilWithoutScreenshot() throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        #expect(home.locator().newestScreenshot() == nil)

        _ = try home.makeFile("notes.png", created: Date())
        #expect(home.locator().newestScreenshot() == nil)

        try FileManager.default.removeItem(at: home.desktop)
        #expect(home.locator().newestScreenshot() == nil)
    }

    // MARK: - Fixtures

    /// Compares folders by real path, since the temporary directory sits behind `/var` -> `/private/var`.
    private static func resolved(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    /// Writes `kMDItemIsScreenCapture = true` the way macOS stores it: a binary plist in an extended attribute.
    private static func markAsScreenCapture(_ url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: true, format: .binary, options: 0)
        let status = data.withUnsafeBytes { buffer in
            setxattr(url.path, ScreenshotLocator.screenCaptureAttributeName, buffer.baseAddress, buffer.count, 0, XATTR_NOFOLLOW)
        }
        let setxattrErrno = errno
        #expect(status == 0, "setxattr errno \(setxattrErrno)")
    }

    /// A throwaway home directory with an empty `Desktop`.
    private struct TemporaryHome {
        let root: URL
        let desktop: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-screenshot-locator-\(UUID().uuidString)", isDirectory: true)
            desktop = root.appendingPathComponent("Desktop", isDirectory: true)
            try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        }

        func locator(_ preferences: [String: String] = [:]) -> ScreenshotLocator {
            ScreenshotLocator(
                preferences: FakeScreenCapturePreferences(values: preferences),
                fileManager: .default,
                homeDirectory: root
            )
        }

        func makeDirectory(_ relativePath: String) throws -> URL {
            let url = root.appendingPathComponent(relativePath, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func makeFile(_ name: String, in directory: URL? = nil, created: Date) throws -> URL {
            let url = (directory ?? desktop).appendingPathComponent(name, isDirectory: false)
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url)
            try FileManager.default.setAttributes(
                [.creationDate: created, .modificationDate: created],
                ofItemAtPath: url.path
            )
            return url
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
