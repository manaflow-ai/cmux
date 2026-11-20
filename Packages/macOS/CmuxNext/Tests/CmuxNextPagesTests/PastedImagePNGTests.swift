import AppKit
@testable import CmuxNextPages
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// https://github.com/manaflow-ai/cmux/issues/41016: a picture copied as TIFF only (Preview, Safari's
/// Copy Image) pasted slowly into the agent chat. Chromium encoded the PNG it reads with ImageIO's
/// default filter search while the page waited (300 ms and more for a 5K screenshot). The host now
/// adds a PNG without that search before Chromium reads the pasteboard (``PastedImagePNG``).
/// Serialized: the timing test measures encodes that the other tests would run beside it.
@MainActor @Suite(.serialized)
struct PastedImagePNGTests {
    /// The same picture on every run: the encode times compare like with like.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// A Retina screenshot's size (3456 x 2234) with an editor's look: lines of anti-aliased code in
    /// a few colours. Text is what makes a screenshot's PNG slow to encode: flat shapes are not.
    static let screenshot: Data = {
        let (width, height) = (3456, 2234)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Menlo" as CFString, 26, nil)
        let colors = [(0.83, 0.83, 0.83), (0.61, 0.86, 1.0), (0.81, 0.57, 0.47), (0.42, 0.6, 0.33), (0.77, 0.53, 0.75)]
        let letters = Array("abcdefghijklmnopqrstuvwxyz0123456789_(){}.;=")
        var generator = Seeded()
        for (line, y) in stride(from: height - 40, to: 0, by: -36).enumerated() {
            var text = String(format: "%4d  ", line)
            while text.count < 200 {
                text += String((0..<Int.random(in: 2...10, using: &generator)).map { _ in letters.randomElement(using: &generator)! }) + " "
            }
            let (red, green, blue) = colors[line % colors.count]
            let attributes: [CFString: Any] = [kCTFontAttributeName: font,
                                               kCTForegroundColorAttributeName: CGColor(red: red, green: green, blue: blue, alpha: 1)]
            let drawn = CTLineCreateWithAttributedString(CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary))
            context.textPosition = CGPoint(x: 20, y: y)
            CTLineDraw(drawn, context)
        }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return out as Data
    }()

    /// Whether this process reaches a pasteboard server: a fleet test step often does not, and there
    /// every write fails and every read returns nil (as AttachmentSourceTests finds).
    nonisolated static let hasPasteboard: Bool = {
        let board = NSPasteboard(name: NSPasteboard.Name("cmux-pasted-png-probe-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        return board.setString("probe", forType: .string) && board.string(forType: .string) == "probe"
    }()

    private func board() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("cmux-pasted-png-\(UUID().uuidString)"))
    }

    @Test func onlyAPlainPictureHeldAsTIFFNeedsAPNG() {
        let converter = PastedImagePNG()
        #expect(converter.needsPNG(items: [["public.tiff"]]))
        #expect(converter.needsPNG(items: [["public.tiff", "NeXT TIFF v4.0 pasteboard type", "org.nspasteboard.source", "public.url"]]))
        #expect(!converter.needsPNG(items: [["public.tiff", "public.png"]]))
        #expect(!converter.needsPNG(items: [["public.file-url", "public.tiff"]]))
        #expect(!converter.needsPNG(items: [["public.utf8-plain-text"]]))
        // Contents a password manager or another device wrote, two items, and a document's formats.
        #expect(!converter.needsPNG(items: [["public.tiff", "org.nspasteboard.ConcealedType"]]))
        #expect(!converter.needsPNG(items: [["public.tiff", "org.nspasteboard.TransientType"]]))
        #expect(!converter.needsPNG(items: [["public.tiff", "com.apple.is-remote-clipboard"]]))
        #expect(!converter.needsPNG(items: [["public.tiff"], ["public.tiff"]]))
        #expect(!converter.needsPNG(items: [["public.tiff", "com.adobe.pdf", "com.microsoft.Powerpoint-14.0-Slides-Package"]]))
        #expect(!converter.needsPNG(items: [["public.tiff", "com.apple.pasteboard.promised-file-url"]]))
    }

    @Test(.enabled(if: hasPasteboard, "needs a pasteboard server"))
    func thePasteboardKeepsEveryTypeAndGainsAPNGOfTheSamePicture() async throws {
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents()
        let item = NSPasteboardItem()
        item.setData(Self.screenshot, forType: .tiff)
        item.setString("com.apple.Preview", forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        #expect(board.writeObjects([item]))
        let written = await PastedImagePNG().addPNG(pasteboard: board.name, changeCount: board.changeCount)
        #expect(written == board.changeCount)
        let types = Set(board.types?.map(\.rawValue) ?? [])
        #expect(types.isSuperset(of: ["public.tiff", "public.png", "org.nspasteboard.source"]))
        #expect(board.data(forType: .tiff) == Self.screenshot)
        #expect(board.string(forType: NSPasteboard.PasteboardType("org.nspasteboard.source")) == "com.apple.Preview")
        let png = try #require(board.data(forType: .png))
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect((image.width, image.height) == (3456, 2234))
    }

    @Test(.enabled(if: hasPasteboard, "needs a pasteboard server"))
    func aPasteboardThatChangedMeanwhileIsLeftAsItIs() async {
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Self.screenshot, forType: .tiff)
        let before = board.changeCount
        board.clearContents()
        board.setString("newer", forType: .string)
        #expect(await PastedImagePNG().addPNG(pasteboard: board.name, changeCount: before) == nil)
        #expect(board.string(forType: .string) == "newer")
        #expect(board.data(forType: .png) == nil)
    }

    /// The timing test, part one: a Retina screenshot's PNG with no filter search takes less than
    /// the default encode Chromium's read ran, measured beside it on the same machine.
    @Test func thePNGIsMadeFasterThanChromiumsOwnEncode() {
        let converter = PastedImagePNG()
        func median(_ run: () -> Void) -> Double {
            (0..<3).map { _ in
                let start = ContinuousClock.now
                run()
                return (ContinuousClock.now - start) / .milliseconds(1)
            }.sorted()[1]
        }
        let ours = median { _ = converter.png(fromTIFF: Self.screenshot) }
        // What Chromium's read ran: the same image as PNG with ImageIO's defaults.
        let chromiums = median {
            let source = CGImageSourceCreateWithData(Self.screenshot as CFData, nil)!
            let out = NSMutableData()
            let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, CGImageSourceCreateImageAtIndex(source, 0, nil)!, nil)
            _ = CGImageDestinationFinalize(destination)
        }
        print("PastedImagePNG: ours \(Int(ours)) ms, Chromium's default encode \(Int(chromiums)) ms")
        // Faster on the same picture and machine. How much faster depends on the picture: 1.3x for
        // this one on aws-m4pro-7 (135 vs 179 ms), 2 to 3x for a real 5K screenshot on an M-series
        // laptop (100-195 vs 326-411 ms).
        #expect(ours < chromiums)
    }

    /// The timing test, part two: the held Cmd-V resumes once the PNG is on the pasteboard, and the
    /// hold is measured and printed. It asserts on the resume, not on the milliseconds: a fixed
    /// wall-clock bound fails on a loaded runner and is refused by the test-determinism gate
    /// (assert-on-duration). Part one compares the encode with Chromium's on the same machine.
    @Test(.enabled(if: hasPasteboard, "needs a pasteboard server"))
    func aHeldPasteResumesWithItsPNG() async {
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Self.screenshot, forType: .tiff)
        let hold = PastedImagePNGHold()
        let start = ContinuousClock.now
        let added: Bool? = await withCheckedContinuation { done in
            if !hold.hold(board, resume: { done.resume(returning: $0) }) { done.resume(returning: nil) }
        }
        let held = (ContinuousClock.now - start) / .milliseconds(1)
        print("PastedImagePNG: Cmd-V held \(Int(held)) ms")
        // For comparison, Chromium's own read of this picture took about 150 ms for 3.4K on an
        // M-series laptop, and 300 ms and more for 5K.
        #expect(added == true)
        // The paste that goes on is never held again.
        let heldAgain = hold.hold(board, resume: { _ in Issue.record("held twice") })
        #expect(!heldAgain)
    }

    @Test(.enabled(if: hasPasteboard, "needs a pasteboard server"))
    func aSecondPasteDuringTheHoldWaitsForThePNGToo() async {
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Self.screenshot, forType: .tiff)
        let hold = PastedImagePNGHold()
        final class Order { var names: [String] = [] }
        let order = Order()
        let both: Void = await withCheckedContinuation { done in
            let first = hold.hold(board, resume: { _ in order.names.append("first") })
            let second = first && hold.hold(board, resume: { added in
                order.names.append("second")
                #expect(added)
                done.resume()
            })
            if !second { done.resume() }
        }
        _ = both
        #expect(order.names == ["first", "second"])
        #expect(board.types?.contains(.png) == true)
        #expect(board.data(forType: .png) != nil)
    }

    /// A conversion that takes longer than its deadline (the copying app is slow to hand over its
    /// picture) lets the paste go on without it, so no Cmd-V waits behind a hung app.
    @Test(.enabled(if: hasPasteboard, "needs a pasteboard server"))
    func aPastePastItsDeadlineGoesOnWithoutThePNG() async {
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Self.screenshot, forType: .tiff)
        let hold = PastedImagePNGHold(deadline: .zero)
        let added: Bool? = await withCheckedContinuation { done in
            if !hold.hold(board, resume: { done.resume(returning: $0) }) { done.resume(returning: nil) }
        }
        #expect(added == false)
        // The next paste is not queued behind the one that ran out.
        let next: Bool? = await withCheckedContinuation { done in
            if !hold.hold(board, resume: { done.resume(returning: $0) }) { done.resume(returning: nil) }
        }
        #expect(next != false)
    }
}
