import AppKit
import CmuxHomeCore
import Testing
@testable import MessagesLabHome

/// MessagesLab's Markdown security settings are set before Home's first
/// Markdown parse (parsed documents and layouts are cached): no extra link
/// scheme, and images only from Home's own attachment pictures.
@MainActor @Suite(.serialized) struct HomeMarkdownPolicyTests {
    @Test func thePolicyIsSetBeforeTheFirstTranscriptRender() throws {
        HomeMarkdownPolicy.installed = false
        MarkdownImages.provider = nil
        MarkdownLinkPolicy.extraSchemes = ["cmux"]
        let (p, c) = Fixture2.projection()
        #expect(MarkdownImages.provider === HomeMarkdownPolicy.images, "the pane controller installs the policy at init")
        #expect(MarkdownLinkPolicy.extraSchemes.isEmpty)
        p.apply(items: [Fixture2.item(1, Fixture2.them, "**Hi** there")], summary: Fixture2.summary(lastSeq: 1), typing: [], hasOlder: false)
        c.host.layoutSubtreeIfNeeded(); c.demo!.layoutIfNeeded(); c.demo!.collection.layoutIfNeeded()
        #expect(MarkdownImages.provider === HomeMarkdownPolicy.images && MarkdownLinkPolicy.extraSchemes.isEmpty, "still set after the render")
        // MessagesLab's engine under Home's policy: an image is its text, never fetched.
        let md = try #require(Markdown.layout("**Look** ![chart](https://example.com/c.png)", message: nil, format: .markdown, width: 628))
        #expect(md.plain.contains("[Image: chart]"), "\(md.plain)")
        #expect(MDInlineParser.parse("[run](cmux://open)").spans.compactMap(\.link).isEmpty, "no extra scheme is a link")
    }

    @Test func theSidebarPreviewInstallsThePolicyToo() {
        HomeMarkdownPolicy.installed = false
        MarkdownImages.provider = nil
        _ = HomeMarkdownPreview("**Done**", author: Fixture2.them, in: Fixture2.summary(lastSeq: 1))
        #expect(MarkdownImages.provider === HomeMarkdownPolicy.images)
    }

    @Test func imagesComeOnlyFromHomesAttachmentPictures() throws {
        let images = HomeMarkdownPolicy.images
        try FileManager.default.createDirectory(at: HomeMedia.directory, withIntermediateDirectories: true)
        let inside = HomeMedia.directory.appendingPathComponent("policy-test-\(UUID().uuidString).png")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("policy-test-\(UUID().uuidString).png")
        for url in [inside, outside] { try Self.png(url) }
        defer { for url in [inside, outside] { try? FileManager.default.removeItem(at: url) } }
        #expect(images.markdownImage(source: inside.absoluteString, alt: "a") != nil, "an attachment picture shows")
        #expect(images.markdownImage(source: outside.absoluteString, alt: "a") == nil, "another file does not")
        #expect(images.markdownImage(source: HomeMedia.directory.appendingPathComponent("../x.png").absoluteString, alt: "a") == nil)
        #expect(images.markdownImage(source: "https://example.com/c.png", alt: "a") == nil, "nothing is fetched")
        #expect(images.markdownImage(source: inside.lastPathComponent, alt: "a") == nil, "a relative source is not a file")
    }

    static func png(_ url: URL) throws {
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let rep = NSBitmapImageRep(cgImage: try #require(ctx.makeImage()))
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
