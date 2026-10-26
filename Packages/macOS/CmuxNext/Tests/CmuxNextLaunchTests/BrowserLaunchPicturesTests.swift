import AppKit
import CmuxNextDesign
import CmuxNextLaunch
import CmuxNextWakeups
import Foundation
import Testing

/// The browser pages' pictures from the last quit (p08-startup-043): written per profile, private, never for an
/// incognito, Secure Input, protected-media or capture-hidden page; read off the main thread at launch, handed out
/// once and never waited for; the untaken ones dropped after the keep; and a pane of another size shows none.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(1)))
struct BrowserLaunchPicturesTests {
    static let work = BackgroundWork(label: "test.browser-launch-pictures")
    static let profile = UUID()
    static let incognitoProfile = UUID()
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

    static func shot(_ key: String, profile: UUID = profile, withheld: BrowserLaunchPictures.Withheld = []) throws
        -> BrowserLaunchPictures.Shot {
        BrowserLaunchPictures.Shot(key: key, profile: profile, withheld: withheld, picture: try picture())
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

    @Test func anIncognitoPageIsNeverWritten() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        await BrowserLaunchPictures(directory: directory, work: Self.work).save([
            try Self.shot("tab_shown"),
            try Self.shot("tab_incognito", profile: Self.incognitoProfile, withheld: .offTheRecord),
            try Self.shot("tab_password", withheld: .secureInput),
            try Self.shot("tab_drm", withheld: .protectedMedia),
            try Self.shot("tab_private_window", withheld: .hiddenFromCapture),
        ])
        let profile = Self.profile.uuidString
        #expect(Self.files(under: directory) == [profile, "\(profile)/pictures.json", "\(profile)/tab_shown.jpg"],
                "a withheld page was written")
        let index = try String(contentsOf: directory.appending(path: "\(profile)/pictures.json"), encoding: .utf8)
        #expect(!index.contains("tab_incognito") && !index.contains("tab_password") && !index.contains("tab_drm"),
                "the index names a withheld page")
    }

    @Test func onlyIncognitoPagesOnScreenLeaveNoPictureOfTheLastQuit() async throws {
        let directory = Self.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await Self.saved(["tab_a"], in: directory)
        await BrowserLaunchPictures(directory: directory, work: Self.work).save([
            try Self.shot("tab_incognito", profile: Self.incognitoProfile, withheld: .offTheRecord),
        ])
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
