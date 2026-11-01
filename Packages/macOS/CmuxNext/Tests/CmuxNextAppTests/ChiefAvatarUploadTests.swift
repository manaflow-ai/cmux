@testable import CmuxNextFloating
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// Leo 2026-10-26: "have guys make their own and then, like, upload their own if they have things
/// from elsewhere for the avatars, the Chief avatars." The store of those uploads: a still or a moving
/// GIF checked against the limits, drawn down, kept per key on this Mac only, found again at the next
/// launch, and removed on Remove. Every picture here is drawn by the test.
@MainActor @Suite(.serialized) struct ChiefAvatarUploadTests {
    static let chief = "agent_mux"

    /// A temporary folder the test removes.
    static func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cnc-avatar-uploads-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A synthetic picture: `frames` flat colors of `width` x `height`, written as `type`.
    static func picture(_ type: UTType, width: Int, height: Int, frames: Int = 1, in folder: URL) throws -> URL {
        let file = folder.appending(path: "synthetic-\(UUID().uuidString).\(type.preferredFilenameExtension ?? "img")")
        let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, type.identifier as CFString, frames, nil))
        for index in 0..<frames {
            let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(red: CGFloat(index % 2), green: 0.5, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let frame: [CFString: Any] = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.25]]
            CGImageDestinationAddImage(destination, try #require(context.makeImage()), frame as CFDictionary)
        }
        #expect(CGImageDestinationFinalize(destination))
        return file
    }

    static func pixels(_ file: URL) -> (Int, Int)? {
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let header = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return (header[kCGImagePropertyPixelWidth] as? Int ?? 0, header[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test func aLargeStillIsDrawnDownWornAndKeptAcrossLaunches() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploads = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        let key = ChiefAvatarUploads.key(chief: Self.chief)
        try await uploads.store(from: Self.picture(.png, width: 1600, height: 900, in: folder), for: key, over: "orb")
        let upload = try #require(uploads.worn(of: key, over: "orb"))
        #expect(upload.file == upload.still, "a still has no moving file")
        #expect(uploads.image(at: upload.still)?.width == ChiefAvatarUploads.stillSide, "decoded before it is published")
        let (width, height) = try #require(Self.pixels(upload.still))
        #expect(max(width, height) == ChiefAvatarUploads.stillSide)
        #expect(upload.still.path.hasPrefix(folder.path), "kept in the uploads folder only")
        // The next launch finds it as it was left.
        let again = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        await Self.until { again.uploads[key] != nil }
        #expect(again.uploads[key] == upload)
        #expect(again.image(at: upload.still) != nil)
    }

    @Test func aRemovalThenAnUploadKeepsTheUpload() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploads = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        let key = ChiefAvatarUploads.key(chief: Self.chief)
        try await uploads.store(from: Self.picture(.png, width: 64, height: 64, in: folder), for: key, over: "orb")
        uploads.remove(key)
        try await uploads.store(from: Self.picture(.png, width: 80, height: 80, in: folder), for: key, over: "orb")
        let upload = try #require(uploads.worn(of: key, over: "orb"))
        // The removal ran first, in order: the newer upload's files are still there for the next launch.
        let again = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        await Self.until { again.uploads[key] != nil }
        #expect(again.uploads[key] == upload)
        #expect(Self.pixels(upload.still)?.0 == 80)
    }

    @Test func onlyKeysTheStoreMakesNameAFolder() async throws {
        #expect(ChiefAvatarUploads.isKey(ChiefAvatarUploads.key(chief: "../agent_mux/..")))
        #expect(ChiefAvatarUploads.isKey(ChiefAvatarUploads.key(agent: "sess-1")))
        for bad in ["", "chief-", "../outside", "chief-../x", "chief-a/b", "agent-.", "other-x"] {
            #expect(!ChiefAvatarUploads.isKey(bad), "\(bad)")
        }
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploads = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        let file = try Self.picture(.png, width: 32, height: 32, in: folder)
        await #expect(throws: ChiefAvatarUploads.Refusal.unsaved) { try await uploads.store(from: file, for: "../outside", over: "orb") }
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "outside").path))

        // An uploads folder that is a link is never written through either.
        let linkedRoot = folder.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: folder.appending(path: "elsewhere-root"))
        try FileManager.default.createDirectory(at: folder.appending(path: "elsewhere-root"), withIntermediateDirectories: true)
        await #expect(throws: ChiefAvatarUploads.Refusal.unsaved) {
            try await ChiefAvatarUploads(folder: linkedRoot).store(from: file, for: ChiefAvatarUploads.key(chief: Self.chief), over: "orb")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.appending(path: "elsewhere-root").path).isEmpty)

        // A key's folder that is a link to another folder is never written through.
        let elsewhere = folder.appending(path: "elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appending(path: "uploads"), withIntermediateDirectories: true)
        let key = ChiefAvatarUploads.key(chief: Self.chief)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "uploads").appending(path: key), withDestinationURL: elsewhere)
        await #expect(throws: ChiefAvatarUploads.Refusal.unsaved) { try await uploads.store(from: file, for: key, over: "orb") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    @Test func aRefusedUploadAfterAGoodOneKeepsTheGoodOne() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploads = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        let key = ChiefAvatarUploads.key(chief: Self.chief)
        let good = try Self.picture(.png, width: 50, height: 50, in: folder)
        let bad = folder.appending(path: "bad.png")
        try Data("not a picture".utf8).write(to: bad)
        // Both begin before either lands: the refused one is the newer.
        let first = Task { try await uploads.store(from: good, for: key, over: "orb") }
        let second = Task { try await uploads.store(from: bad, for: key, over: "orb") }
        try await first.value
        await #expect(throws: ChiefAvatarUploads.Refusal.unreadable) { try await second.value }
        #expect(uploads.worn(of: key, over: "orb").flatMap { Self.pixels($0.still)?.0 } == 50)
    }

    /// The four orders of (the launch listing, an upload, a removal, a pick) the person can make
    /// in, every one: what shows, and what the next launch finds, is the newest intent's.
    @Test func theNewestIntentWinsInEveryOrderAroundTheLaunchListing() async throws {
        enum Step: CaseIterable { case listing, upload, removal, pick }
        func orders(_ steps: [Step]) -> [[Step]] {
            steps.count <= 1 ? [steps] : steps.indices.flatMap { index in
                var rest = steps
                let first = rest.remove(at: index)
                return orders(rest).map { [first] + $0 }
            }
        }
        let key = ChiefAvatarUploads.key(chief: Self.chief)
        for order in orders(Step.allCases) {
            let folder = try Self.folder()
            defer { try? FileManager.default.removeItem(at: folder) }
            let root = folder.appending(path: "uploads")
            try await ChiefAvatarUploads(folder: root).store(from: Self.picture(.png, width: 40, height: 40, in: folder), for: key, over: "orb")
            let next = try Self.picture(.png, width: 60, height: 60, in: folder)
            let uploads = ChiefAvatarUploads(folder: root)  // its listing starts now
            // What the person asked for, in order: the last launch's upload, worn over orb, first.
            var expected: (width: Int, wornOver: String?)? = (40, "orb")
            var upload: Task<Result<Void, ChiefAvatarUploads.Refusal>, Never>?
            for step in order {
                switch step {
                case .listing: await uploads.settled()
                case .upload:
                    upload = uploads.storing(from: next, for: key, over: "orb")
                    expected = (60, "orb")
                case .removal:
                    uploads.remove(key)
                    expected = nil
                case .pick:
                    uploads.wear(key, over: nil)
                    expected?.wornOver = nil
                }
            }
            try await upload?.value.get()
            await uploads.settled()
            let again = ChiefAvatarUploads(folder: root)
            await again.settled()
            for (store, moment) in [(uploads, "now"), (again, "next launch")] {
                let found = store.uploads[key]
                #expect(found.flatMap { Self.pixels($0.still)?.0 } == expected?.width, "\(order) \(moment)")
                #expect(found?.wornOver == expected?.wornOver, "\(order) \(moment)")
            }
        }
    }

    @Test func aPickAndTheNewestUploadAreWhatTheNextLaunchFinds() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploads = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        let key = ChiefAvatarUploads.key(chief: Self.chief)
        try await uploads.store(from: Self.picture(.png, width: 40, height: 40, in: folder), for: key, over: "orb")
        try await uploads.store(from: Self.picture(.png, width: 60, height: 60, in: folder), for: key, over: "orb")
        uploads.wear(key, over: nil)  // a character picked
        #expect(uploads.uploads[key]?.wornOver == nil && uploads.worn(of: key, over: "orb") == nil)
        let again = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        await Self.until { again.uploads[key] != nil }
        #expect(again.uploads[key]?.wornOver == nil, "the marker follows the pick too")
        #expect(Self.pixels(try #require(again.uploads[key]).still)?.0 == 60, "the newest upload is the one found")
    }

    @Test func aSmallMovingGIFIsKeptAsGivenAndTheLimitsRefuseTheRest() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let uploads = ChiefAvatarUploads(folder: folder.appending(path: "uploads"))
        let key = ChiefAvatarUploads.key(chief: Self.chief)
        try await uploads.store(from: Self.picture(.gif, width: 64, height: 64, frames: 3, in: folder), for: key, over: "orb")
        let upload = try #require(uploads.worn(of: key, over: "orb"))
        #expect(upload.file.pathExtension == "gif" && upload.file != upload.still)

        let refusals: [(URL, ChiefAvatarUploads.Refusal)] = [
            (try Self.picture(.gif, width: 300, height: 300, frames: 2, in: folder), .gifTooBig),
            (try Self.picture(.png, width: 9000, height: 10, in: folder), .tooManyPixels),
        ]
        let text = folder.appending(path: "notes.png")
        try Data("not a picture".utf8).write(to: text)
        for (file, reason) in refusals + [(text, .unreadable)] {
            await #expect(throws: reason) { try await uploads.store(from: file, for: key, over: "orb") }
        }
        #expect(uploads.worn(of: key, over: "orb") == upload, "a refused upload leaves the one before")
        #expect(!ChiefAvatarUploads.Refusal.gifTooBig.message.isEmpty)
    }

    /// Waits for `condition` up to a deadline: the uploads and settings change on other tasks.
    static func until(_ condition: () -> Bool, within timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}
