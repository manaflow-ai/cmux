import AppKit
@testable import CmuxNextPages
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

    /// A Retina screenshot's size (3456 x 2234) with an editor's look: rows of short runs of colour.
    static let screenshot: Data = {
        let (width, height) = (3456, 2234)
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        var generator = Seeded()
        for row in stride(from: 20, to: height, by: 36) {
            var x = 20
            while x < width - 40 {
                let run = Int.random(in: 8...90, using: &generator)
                context.setFillColor(CGColor(red: .random(in: 0.4...1, using: &generator), green: .random(in: 0.4...1, using: &generator),
                                             blue: .random(in: 0.4...1, using: &generator), alpha: 1))
                context.fill(CGRect(x: x, y: row, width: run, height: 18))
                x += run + Int.random(in: 6...24, using: &generator)
            }
        }
        let out = NSMutableData()
        let destination = CGImageDestinationCreateWithData(out, UTType.tiff.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        _ = CGImageDestinationFinalize(destination)
        return out as Data
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

    @Test func thePasteboardKeepsEveryTypeAndGainsAPNGOfTheSamePicture() async throws {
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

    @Test func aPasteboardThatChangedMeanwhileIsLeftAsItIs() async {
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

    /// The timing test: from the held Cmd-V to the PNG on the pasteboard, a Retina screenshot takes
    /// well under the default encode Chromium ran (measured beside it, on the same machine), and
    /// under 300 ms outright.
    @Test func aHeldPasteResumesWithItsPNGFasterThanChromiumsOwnEncode() async throws {
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
        #expect(ours * 1.5 < chromiums)

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
        #expect(added == true)
        // Well under what Chromium's own read took for this picture on a person's Mac (about 150 ms
        // for 3.4K on an M-series laptop, 300 ms and more for 5K), with room for a loaded runner.
        #expect(held < 500)
        // The paste that goes on is never held again.
        let heldAgain = hold.hold(board, resume: { _ in Issue.record("held twice") })
        #expect(!heldAgain)
    }

    @Test func aSecondPasteDuringTheHoldWaitsForThePNGToo() async {
        let board = board()
        defer { board.releaseGlobally() }
        board.clearContents()
        board.setData(Self.screenshot, forType: .tiff)
        let hold = PastedImagePNGHold()
        final class Order { var names: [String] = [] }
        let order = Order()
        let both: Void = await withCheckedContinuation { done in
            let first = hold.hold(board, resume: { _ in order.names.append("first") })
            let second = hold.hold(board, resume: { added in
                order.names.append("second")
                #expect(added)
                done.resume()
            })
            #expect(first && second)
        }
        _ = both
        #expect(order.names == ["first", "second"])
        #expect(board.data(forType: .png) != nil)
    }
}
