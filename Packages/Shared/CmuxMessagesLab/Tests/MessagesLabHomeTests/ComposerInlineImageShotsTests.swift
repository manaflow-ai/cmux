import AppKit
@testable import CmuxHomeCore
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MessagesLabHome

/// The Home message box with pictures in its text, as in Messages (Lawrence 2026-10-20, with a
/// capture of Messages' box, cmux-prompts/refs/composer-images/1.png: each pasted picture is a
/// rounded thumbnail 176 pt wide in the text flow, the text under and between the pictures, the
/// field grows to its maximum height and then scrolls; the sent message shows the same pictures).
///
/// `everyStateRendersToTheShots` draws the real Home view over the mock owner in each state, light
/// and dark, wide and narrow, into `.build/composer-inline-shots.zip` (a fleet step returns it
/// with `--artifact Packages/Shared/CmuxMessagesLab/.build/composer-inline-shots.zip`). The other
/// tests check the behaviour the pictures show.
@MainActor @Suite(.serialized) struct ComposerInlineImageShotsTests {
    // MARK: Pictures

    /// A W x H px opaque PNG: a vertical gradient from HUE with a white band across its middle, so
    /// a shot shows the picture's aspect and that it is not cropped.
    nonisolated static func png(_ w: Int, _ h: Int, hue: CGFloat) throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        let top = NSColor(hue: hue, saturation: 0.6, brightness: 0.95, alpha: 1).cgColor
        let bottom = NSColor(hue: hue, saturation: 0.9, brightness: 0.5, alpha: 1).cgColor
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [top, bottom] as CFArray, locations: [0, 1]))
        ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: h), end: .zero, options: [])
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        ctx.fill(CGRect(x: 0, y: h / 2 - h / 20, width: w, height: h / 10))
        ctx.setStrokeColor(CGColor(gray: 0, alpha: 0.6))
        ctx.setLineWidth(CGFloat(max(w, h)) / 100)
        ctx.stroke(CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: CGFloat(max(w, h)) / 200, dy: CGFloat(max(w, h)) / 200))
        let image = try #require(ctx.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    /// The pictures of the shots: a window screenshot (1412 x 1106 px at 2x, the reference's first
    /// picture), a wide screenshot (1.9 : 1), and a tall phone screenshot.
    enum Picture: CaseIterable {
        case screenshot, wide, tall
        var pixels: (Int, Int) {
            switch self {
            case .screenshot: (1412, 1106)
            case .wide: (1800, 948)
            case .tall: (800, 1400)
            }
        }
        var hue: CGFloat {
            switch self {
            case .screenshot: 0.58
            case .wide: 0.08
            case .tall: 0.33
            }
        }
    }

    // MARK: Driving the box

    @MainActor struct Box {
        let rig: HomeChatRig
        let dir: URL
        var field: FieldTextView { rig.view.controller.demo!.compose.textView.view }
        var compose: ComposeView { rig.view.controller.demo!.compose }

        func type(_ text: String) {
            if rig.window.firstResponder !== field { _ = rig.window.makeFirstResponder(field) }
            field.insertText(text, replacementRange: field.selectedRange())
            rig.frame()
        }

        /// A picture enters at the caret, through the same intake as a paste (`addDraftAttachment`).
        func paste(_ picture: Picture, _ n: Int = 0) async throws {
            if rig.window.firstResponder !== field { _ = rig.window.makeFirstResponder(field) }
            let (w, h) = picture.pixels
            let url = dir.appendingPathComponent("\(picture)-\(n).png")
            try ComposerInlineImageShotsTests.png(w, h, hue: picture.hue + CGFloat(n) * 0.11).write(to: url)
            let prepared = try await rig.store.prepareAttachment(fileURL: url)
            await rig.view.addDraftAttachment(prepared)
            settle()
        }

        /// Decodes every thumbnail in the field and lays the box out again.
        func settle() {
            if let s = field.textStorage {
                s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
                    (v as? ComposeInlineAttachment)?.loadThumbnailNow(scale: 2)
                }
            }
            for _ in 0..<4 { rig.frame() }
            field.layoutSubtreeIfNeeded()
        }

        var inline: [ComposeInlineAttachment] {
            guard let s = field.textStorage else { return [] }
            var out: [ComposeInlineAttachment] = []
            s.enumerateAttribute(.attachment, in: NSRange(location: 0, length: s.length)) { v, _, _ in
                if let a = v as? ComposeInlineAttachment { out.append(a) }
            }
            return out
        }

        func stop() {
            rig.stop()
            try? FileManager.default.removeItem(at: dir)
        }
    }

    private func box(width: CGFloat = 700) async throws -> Box {
        let rig = try await HomeChatRig(history: 0, width: width)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("composer-inline-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        rig.frame()
        return Box(rig: rig, dir: dir)
    }

    // MARK: The size of a picture, as in Messages

    private func attachment(_ w: Int, _ h: Int) -> MessagesLabHome.Attachment {
        MessagesLabHome.Attachment(id: "p\(w)x\(h)", kind: "image", fileName: "p.png", mimeType: "image/png", byteSize: 1,
                                   asset: "/tmp/p\(w)x\(h).png", poster: nil, width: w, height: h, durationSeconds: nil, transfer: .done)
    }

    /// The reference's first picture, a 1412 x 1106 px screenshot at 2x, is 176 pt wide in
    /// Messages' box (352 px of the 2x capture), at its own aspect.
    @Test func aScreenshotIsAsWideAsInMessages() {
        let s = ComposeInlineAttachment.size(of: attachment(1412, 1106), scale: 2)
        #expect(abs(s.width - 176) <= 1, "\(s)")
        #expect(abs(s.width / s.height - 1412.0 / 1106.0) < 0.02, "the picture's aspect (\(s))")
    }

    /// A wide screenshot takes the same width, shorter.
    @Test func aWidePictureTakesTheSameWidth() {
        let s = ComposeInlineAttachment.size(of: attachment(1800, 948), scale: 2)
        #expect(abs(s.width - 176) <= 1, "\(s)")
        #expect(abs(s.height - 92.5) <= 1, "\(s)")
    }

    /// A tall picture stops at the same height, narrower.
    @Test func aTallPictureStopsAtTheMaxHeight() {
        let s = ComposeInlineAttachment.size(of: attachment(800, 1400), scale: 2)
        #expect(abs(s.height - ComposeInlineAttachment.pictureMaxHeight) <= 1, "\(s)")
        #expect(s.width < s.height, "\(s)")
        #expect(ComposeInlineAttachment.pictureMaxHeight >= 176, "as tall as it is wide at most")
    }

    /// A small picture keeps its own size (no upscaling).
    @Test func aSmallPictureKeepsItsSize() {
        let s = ComposeInlineAttachment.size(of: attachment(120, 80), scale: 2)
        #expect(s == CGSize(width: 60, height: 40), "\(s)")
    }

    // MARK: Sending in the box's order

    /// Text, a picture, more text: the message goes out in that order, in the local bubble and in
    /// the store, as the person laid it out in the box (the pictures used to go first).
    @Test func theSentMessageKeepsTheBoxOrder() async throws {
        let b = try await box()
        defer { b.stop() }
        b.type("before")
        try await b.paste(.screenshot)
        b.type("after")
        #expect(b.rig.view.draftText == "before\u{FFFC}after")
        #expect(b.rig.view.sendDraft() == nil)
        let local = try #require(b.rig.view.controller.store?.state.conversation.messages.last)
        let shape = local.parts.map { part -> String in
            switch part {
            case let .text(t, _): t
            case .attachment: "[picture]"
            default: "?"
            }
        }
        #expect(shape == ["before", "[picture]", "after"], "the local bubble keeps the box's order (\(shape))")
        await HomeChatRig.until { [store = b.rig.store] in
            store.transcript(for: HomeChatRig.conversation).contains { $0.parts.contains { if case .attachment = $0 { true } else { false } } }
        }
        let item = try #require(b.rig.store.transcript(for: HomeChatRig.conversation).last)
        let stored = item.parts.map { part -> String in
            switch part {
            case let .text(t, _): t
            case .attachment: "[picture]"
            default: "?"
            }
        }
        #expect(stored == ["before", "[picture]", "after"], "the store's message keeps the box's order (\(stored))")
    }

    /// Two pictures with text between them go out as picture, text, picture.
    @Test func picturesAroundTextKeepTheirPlaces() async throws {
        let b = try await box()
        defer { b.stop() }
        try await b.paste(.screenshot)
        b.type("between")
        try await b.paste(.wide)
        #expect(b.rig.view.sendDraft() == nil)
        let local = try #require(b.rig.view.controller.store?.state.conversation.messages.last)
        let shape = local.parts.map { part -> String in
            switch part {
            case let .text(t, _): t
            case .attachment: "[picture]"
            default: "?"
            }
        }
        #expect(shape == ["[picture]", "between", "[picture]"], "\(shape)")
    }

    // MARK: The field's growth

    /// The field grows with each picture up to its maximum height, then its text scrolls.
    @Test func theFieldGrowsToItsMaximumThenScrolls() async throws {
        let b = try await box()
        defer { b.stop() }
        let empty = b.compose.fieldRect.height
        try await b.paste(.screenshot)
        let one = b.compose.fieldRect.height
        #expect(one > empty + 100, "one picture makes the field taller (\(empty) -> \(one))")
        b.type("text under it")
        try await b.paste(.wide, 1)
        try await b.paste(.tall, 2)
        let many = b.compose.fieldRect.height
        #expect(many <= ComposeView.maxHeight + 1, "the field stops at its maximum (\(many))")
        #expect(b.field.frame.height > b.compose.textView.scrollView.contentSize.height + 1, "the text scrolls in the field")
    }

    // MARK: Shots

    enum Scene: String, CaseIterable {
        /// The reference's layout: a picture, two text lines, a second picture.
        case reference
        /// Text before and after one picture.
        case textAround
        /// Two pictures one after the other, then text.
        case twoPictures
        /// A tall picture.
        case tall
        /// More than the field holds: it stops at its maximum and scrolls to the caret.
        case overflow
        /// After Return: the sent message's bubbles.
        case sent
    }

    private func drive(_ scene: Scene, _ b: Box) async throws {
        switch scene {
        case .reference:
            try await b.paste(.screenshot)
            b.type("asdfjisldjflk\ndjsalkfjklasfj\n")
            try await b.paste(.tall, 1)
        case .textAround:
            b.type("Here is the window ")
            try await b.paste(.screenshot)
            b.type("and that is all.")
        case .twoPictures:
            try await b.paste(.screenshot)
            try await b.paste(.wide, 1)
            b.type("Both of these")
        case .tall:
            try await b.paste(.tall)
            b.type("A phone screenshot")
        case .overflow:
            try await b.paste(.screenshot)
            b.type("first\n")
            try await b.paste(.wide, 1)
            b.type("second\n")
            try await b.paste(.tall, 2)
            b.type("third, the caret is here")
        case .sent:
            b.type("Look at this")
            try await b.paste(.screenshot)
            b.type("and this one")
            try await b.paste(.wide, 1)
            _ = b.rig.view.sendDraft()
            await b.rig.view.mediaSettled()
            for _ in 0..<12 {
                b.rig.frame()
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        b.settle()
    }

    private func render(_ b: Box) throws -> CGImage {
        let view = b.rig.view
        let layer = try #require(view.layer)
        let scale: CGFloat = 2
        let size = view.bounds.size
        let ctx = try #require(CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(Fixture.background.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        // The view's layers are y-down (a flipped NSView); a bitmap context is y-up.
        ctx.translateBy(x: 0, y: size.height)
        ctx.scaleBy(x: 1, y: -1)
        layer.render(in: ctx)
        let full = try #require(ctx.makeImage())
        // The bottom of the pane: the box and what sits above it.
        let keep = Int(min(size.height, 520) * scale)
        return try #require(full.cropping(to: CGRect(x: 0, y: full.height - keep, width: full.width, height: keep)))
    }

    @Test func everyStateRendersToTheShots() async throws {
        _ = NSApplication.shared
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let out = package.appendingPathComponent(".build/composer-inline-shots", isDirectory: true)
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let saved = Fixture.lightAppearance
        defer { Fixture.lightAppearance = saved }
        var written = 0
        for light in [false, true] {
            Fixture.lightAppearance = light
            for width: CGFloat in [700, 380] {
                for scene in Scene.allCases {
                    let b = try await box(width: width)
                    b.rig.window.appearance = NSAppearance(named: light ? .aqua : .darkAqua)
                    try await drive(scene, b)
                    let image = try render(b)
                    let name = "\(scene.rawValue)-\(light ? "light" : "dark")-\(Int(width)).png"
                    let dest = try #require(CGImageDestinationCreateWithURL(out.appendingPathComponent(name) as CFURL, UTType.png.identifier as CFString, 1, nil))
                    CGImageDestinationAddImage(dest, image, nil)
                    #expect(CGImageDestinationFinalize(dest))
                    written += 1
                    b.stop()
                }
            }
        }
        #expect(written == 2 * 2 * Scene.allCases.count)
        let zip = package.appendingPathComponent(".build/composer-inline-shots.zip")
        try? FileManager.default.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", out.path, zip.path]
        try ditto.run()
        ditto.waitUntilExit()
        #expect(ditto.terminationStatus == 0)
        print("composer-inline-shots: wrote \(zip.path)")
    }
}
