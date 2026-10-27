#if !canImport(ImageIO)
import Foundation
import Testing
@testable import CmuxHomeCore

/// Attachments where no media reader exists (Linux, AttachmentMedia+NoImageIO.swift): a photo, video or M4A
/// whose location cannot be looked for is refused unless the person keeps location, never sent with it; other
/// files prepare as on Apple platforms, and nothing gets media facts, a preview or a poster.
@MainActor
@Suite struct NoImageIOAttachmentTests {
    func store() throws -> HomeStore {
        HomeStore(source: MockHomeSource(options: .immediate), blobCacheDirectory: try temporaryDirectory())
    }

    @Test func mediaIsRefusedUnlessLocationIsKept() async throws {
        let store = try store()
        for (identifier, name) in [(UTType.jpeg.identifier, "attachment.jpeg"), (UTType.png.identifier, "attachment.png"),
                                   (UTType.mpeg4Movie.identifier, "attachment.mp4"),
                                   (UTType.mpeg4Audio.identifier, "attachment.m4a")] {
            await #expect(throws: HomeAttachmentError.locationNotRemoved(name: name)) {
                try await store.prepareAttachment(data: Data("bytes".utf8), typeIdentifier: identifier)
            }
            let kept = try await store.prepareAttachment(data: Data("bytes".utf8), typeIdentifier: identifier,
                                                         keepLocation: true)
            #expect(kept.ref.width == nil && kept.ref.durationMs == nil)
            #expect(kept.ref.preview == nil && kept.ref.poster == nil)
        }
    }

    @Test func aMediaFileIsRefusedByItsExtension() async throws {
        let store = try store()
        let file = try temporaryDirectory().appendingPathComponent("photo.jpg")
        try Data("not a photo".utf8).write(to: file)
        await #expect(throws: HomeAttachmentError.locationNotRemoved(name: "photo.jpg")) {
            try await store.prepareAttachment(fileURL: file)
        }
        #expect(try await store.prepareAttachment(fileURL: file, keepLocation: true).ref.mimeType == "image/jpeg")
    }

    @Test func otherFilesPrepareAsOnApplePlatforms() async throws {
        let store = try store()
        let text = try await store.prepareAttachment(data: Data("hello".utf8), typeIdentifier: UTType.plainText.identifier)
        #expect(text.ref.mimeType == "text/plain")
        let wav = try await store.prepareAttachment(data: Data("not wav".utf8), typeIdentifier: UTType.wav.identifier)
        #expect(wav.ref.mimeType == "audio/wav")
        // TIFF is converted where ImageIO exists; here nothing reads it, so its bytes are sniffed.
        let tiff = try await store.prepareAttachment(data: Data([0x49, 0x49, 0x2a, 0x00, 0xff]),
                                                     typeIdentifier: UTType.tiff.identifier)
        #expect(tiff.ref.mimeType == HomeAttachmentPolicy.genericFileType)
    }

    @Test func linkPreviewPicturesAndThumbnailsAreRefused() async throws {
        let store = try store()
        let file = try temporaryDirectory().appendingPathComponent("picture.png")
        try Data("png".utf8).write(to: file)
        await #expect(throws: HomeRejection.invalid("not_an_image")) {
            try await store.prepareLinkPreviewImage(fileURL: file)
        }
        #expect(throws: HomeRejection.invalid("no_thumbnail")) {
            try AttachmentMedia.thumbnail(of: file, maxPixel: 64)
        }
    }

    /// The fixed UTType table answers as Apple's does for the types the attachment code names.
    @Test func theTypeTableMatchesApplesAnswers() throws {
        #expect(UTType(filenameExtension: "JPG")?.identifier == "public.jpeg")
        #expect(UTType(mimeType: "audio/mp4")?.preferredFilenameExtension == "m4a")
        #expect(UTType("public.plain-text")?.preferredMIMEType == "text/plain")
        #expect(UTType.svg.conforms(to: .image) && UTType.svg.conforms(to: .data))
        #expect(!UTType.plainText.conforms(to: .image))
        #expect(UTType(filenameExtension: "swift") == nil)
    }
}
#endif
