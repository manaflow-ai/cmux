import AppKit
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextWakeups
import Foundation
import Testing

/// The browser pages' pictures from the last quit: written per profile, private, each save
/// replacing the last; read off the main thread at launch, handed out once and never waited for; the untaken ones
/// dropped after the keep; and a pane of another size shows none, nor tells its page to keep a hole for it. Which
/// pages are never pictured the app decides (`BrowserLaunchPictureShotsTests`).
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserLaunchPicturesTests {
    static let work = BackgroundWork(label: "test.browser-launch-pictures")
    static let profile = UUID()
    static let paneSize = CGSize(width: 400, height: 300)
    static let pageFrame = CGRect(x: 0, y: 40, width: 400, height: 260)

    /// An opaque gray 8x6 image.
    static func image() throws -> CGImage {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 8, height: 6, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                             bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 6))
        return try #require(context.makeImage())
    }

    static func picture() throws -> BrowserLaunchPictures.Picture {
        BrowserLaunchPictures.Picture(image: try image(), paneSize: paneSize, pageFrame: pageFrame)
    }

    static func shot(_ key: String, profile: UUID = profile) throws -> BrowserLaunchPictures.Shot {
        BrowserLaunchPictures.Shot(key: key, profile: profile, picture: try picture())
    }

    static func folder() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "browser-launch-pictures-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    /// Every path under `directory`, relative to it, sorted.
    static func files(under directory: URL) -> [String] {
        ((try? FileManager.default.subpathsOfDirectory(atPath: directory.path)) ?? []).sorted()
    }

    static func permissions(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }

    /// A save in `directory` of the page `key` under the test profile.
    static func saved(_ keys: [String], in directory: URL) async throws {
        await BrowserLaunchPictures(directory: directory, work: work).save(try keys.map { try shot($0) })
    }

    /// A save replaces the last quit's whole set; a quit with no page to picture (every page on screen withheld,
    /// `BrowserLaunchPictureShotsTests`) leaves none of the last quit's pictures.
    @Test func aSaveReplacesTheLastQuitsPictures() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.saved(["tab_a", "tab_b"], in: directory)
        try await Self.saved(["tab_c"], in: directory)
        let profile = Self.profile.uuidString
        #expect(Self.files(under: directory) == [profile, "\(profile)/pictures.json", "\(profile)/tab_c.jpg"],
                "a picture of the last quit stayed")
        await BrowserLaunchPictures(directory: directory, work: Self.work).save([])
        #expect(!FileManager.default.fileExists(atPath: directory.path), "the last quit's pictures stayed")
    }

    @Test func picturesArePrivateAndPerProfile() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = UUID()
        await BrowserLaunchPictures(directory: directory, work: Self.work).save([try Self.shot("tab_a"), try Self.shot("tab_b", profile: other)])
        let first = directory.appending(path: Self.profile.uuidString, directoryHint: .isDirectory)
        let second = directory.appending(path: other.uuidString, directoryHint: .isDirectory)
        #expect(Self.permissions(directory) == 0o700)
        #expect(Self.permissions(first) == 0o700)
        #expect(Self.permissions(first.appending(path: "tab_a.jpg")) == 0o600)
        #expect(Self.permissions(first.appending(path: "pictures.json")) == 0o600)
        #expect(Self.permissions(second.appending(path: "tab_b.jpg")) == 0o600)
        #expect(!FileManager.default.fileExists(atPath: first.appending(path: "tab_b.jpg").path), "a page landed in another profile's folder")
    }

    @Test func theLaunchHandsEachPictureOutOnceUnderItsProfile() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.saved(["tab_a", "tab_b"], in: directory)
        let pictures = BrowserLaunchPictures(directory: directory, work: Self.work)
        pictures.prefetch()
        await pictures.readFinished()
        #expect(pictures.take("tab_a", profile: UUID()) == nil, "a picture was handed to another profile's tab")
        let picture = try #require(pictures.take("tab_a", profile: Self.profile))
        #expect(picture.paneSize == Self.paneSize)
        #expect(picture.pageFrame == Self.pageFrame)
        #expect(picture.image.width == 8 && picture.image.height == 6)
        #expect(pictures.take("tab_a", profile: Self.profile) == nil, "a picture was handed out twice")
        #expect(pictures.take("tab_b", profile: Self.profile) != nil)
    }

    /// The pane's first frame never waits: before the read ends it gets nothing; after, its picture.
    @Test func aPaneBeforeTheReadEndsGetsNoneAndNeverWaits() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.saved(["tab_a"], in: directory)
        let gate = DispatchSemaphore(value: 0)
        let reader = LaunchFileReader { url, maximumBytes in
            gate.wait()
            guard let data = try? Data(contentsOf: url), data.count <= maximumBytes else { return nil }
            return data
        }
        let (marks, mark) = AsyncStream.makeStream(of: String.self)
        var names = marks.makeAsyncIterator()
        let pictures = BrowserLaunchPictures(directory: directory, work: Self.work, reader: reader)
        pictures.prefetch(mark: { mark.yield($0) })
        #expect(pictures.take("tab_a", profile: Self.profile) == nil, "a pane got a picture before the read ended")
        let missed = await names.next()
        #expect(missed == "browser.launch_picture_missed")
        gate.signal() // the index
        gate.signal() // the picture
        await pictures.readFinished()
        let read = await names.next()
        #expect(read == "browser.launch_pictures_read")
        #expect(pictures.take("tab_a", profile: Self.profile) != nil, "a pane shown after the read got no picture")
    }

    @Test func theUntakenPicturesGoOnceDropped() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.saved(["tab_a", "tab_b"], in: directory)
        let (marks, mark) = AsyncStream.makeStream(of: String.self)
        var names = marks.makeAsyncIterator()
        let pictures = BrowserLaunchPictures(directory: directory, work: Self.work)
        pictures.prefetch(mark: { mark.yield($0) })
        await pictures.readFinished()
        let read = await names.next()
        #expect(read == "browser.launch_pictures_read")
        #expect(pictures.take("tab_a", profile: Self.profile) != nil, "a pane before the drop got no picture")
        pictures.dropUnasked()
        let dropped = await names.next()
        #expect(dropped == "browser.launch_pictures_dropped")
        #expect(pictures.take("tab_b", profile: Self.profile) == nil, "an untaken picture outlived the drop")
        pictures.prefetch()
        #expect(pictures.take("tab_b", profile: Self.profile) == nil, "a later prefetch read the pictures again")
    }

    @Test func aPaneOfAnotherSizeShowsNothing() throws {
        let view = BrowserLaunchPictureView(try Self.picture(), tab: "tab_a")
        view.setFrameSize(Self.paneSize)
        #expect(view.showsPicture)
        view.setFrameSize(NSSize(width: Self.paneSize.width + 2, height: Self.paneSize.height))
        #expect(!view.showsPicture, "a picture of another size was shown")
        view.setFrameSize(NSSize(width: Self.paneSize.width, height: Self.paneSize.height - 30))
        #expect(!view.showsPicture, "a picture of another size was shown")
        view.setFrameSize(Self.paneSize)
        #expect(view.showsPicture)
        #expect(view.hitTest(NSPoint(x: 10, y: 10)) == nil, "the picture took a click")
    }

    /// The page under the picture is told to keep a hole for it exactly while the picture shows: in a window, at
    /// its size at the quit. A page replaced meanwhile is let go, and a pane that leaves its window lets its page go.
    @Test func thePageKeepsAHoleOnlyWhileThePictureShows() throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.paneSize), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let pane = NSView(frame: NSRect(origin: .zero, size: Self.paneSize))
        window.contentView?.addSubview(pane)
        let view = BrowserLaunchPictureView(try Self.picture(), tab: "tab_a")
        view.setFrameSize(Self.paneSize)
        var first: [Bool] = [], second: [Bool] = []
        view.onShowsChange = { first.append($0) }
        #expect(first == [false], "a picture in no pane covered its page")
        pane.addSubview(view)
        #expect(first == [false, true])
        view.setFrameSize(NSSize(width: Self.paneSize.width - 10, height: Self.paneSize.height))
        #expect(first == [false, true, false], "a picture of another size kept its page covered")
        view.setFrameSize(Self.paneSize)
        #expect(first == [false, true, false, true])
        view.onShowsChange = { second.append($0) }
        #expect(first == [false, true, false, true, false], "the replaced page stayed covered")
        #expect(second == [true])
        pane.removeFromSuperview()
        #expect(second == [true, false], "a page stayed covered by a pane out of its window")
        window.contentView?.addSubview(pane)
        #expect(second == [true, false, true])
        view.removeFromSuperview()
        #expect(second == [true, false, true, false], "the page stayed covered after the picture went")
    }

    @Test func aStaleIndexEntryOrAnUnsafeKeyIsNotRead() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.saved(["tab_a"], in: directory)
        let folder = directory.appending(path: Self.profile.uuidString, directoryHint: .isDirectory)
        // An index that names a missing file and a path outside the folder.
        let index = #"[{"key":"tab_a","pane":[400,300],"page":[[0,40],[400,260]]},{"key":"tab_gone","pane":[400,300],"page":[[0,0],[400,300]]},{"key":"../x","pane":[400,300],"page":[[0,0],[400,300]]}]"#
        try Data(index.utf8).write(to: folder.appending(path: "pictures.json"))
        let pictures = BrowserLaunchPictures(directory: directory, work: Self.work)
        pictures.prefetch()
        await pictures.readFinished()
        #expect(pictures.take("tab_a", profile: Self.profile) != nil)
        #expect(pictures.take("tab_gone", profile: Self.profile) == nil)
        #expect(pictures.take("../x", profile: Self.profile) == nil)
    }
}
