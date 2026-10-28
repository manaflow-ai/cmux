import AppKit
import CoreText
import Foundation
import Testing
@testable import MessagesLabHome

/// Strict memory safety: the pointer-free wrappers (`Cmux/MemorySafeCalls.swift`,
/// `AssociationKey`) and the vendored code moved off raw pointers (LinkGuard's address bytes, GlassKeyFix's
/// over-blend maps, LongText's byte scan) give the results the pointer code gave.
@MainActor @Suite(.serialized) struct MemorySafeCallsTests {
    // MARK: LinkGuard: the address bytes come from the parsed value, in network order

    @Test func linkGuardReadsIPv4BytesInNetworkOrder() {
        // 10.0.0.1 is private; its bytes the other way round (1.0.0.10) are public, so a byte-order slip shows.
        #expect(!LinkGuard.isPublicAddress("10.0.0.1"))
        #expect(LinkGuard.isPublicAddress("1.0.0.10"))
        #expect(!LinkGuard.isPublicAddress("100.64.0.1"))
        #expect(!LinkGuard.isPublicAddress("127.0.0.1"))
        #expect(!LinkGuard.isPublicAddress("192.168.4.2"))
        #expect(LinkGuard.isPublicAddress("8.8.8.8"))
    }

    @Test func linkGuardReadsAllSixteenIPv6Bytes() {
        #expect(!LinkGuard.isPublicAddress("::1"))
        #expect(!LinkGuard.isPublicAddress("fe80::1"))
        #expect(!LinkGuard.isPublicAddress("fd00::1"))
        #expect(!LinkGuard.isPublicAddress("2001:db8::1"))
        // The mapped forms read the last four bytes as IPv4.
        #expect(!LinkGuard.isPublicAddress("::ffff:10.0.0.1"))
        #expect(LinkGuard.isPublicAddress("::ffff:8.8.8.8"))
        #expect(LinkGuard.isPublicAddress("2606:4700:4700::1111"))
    }

    @Test func linkGuardTellsAddressLiteralsFromNames() {
        #expect(LinkGuard.isIPLiteral("192.168.1.1"))
        #expect(LinkGuard.isIPLiteral("::1"))
        #expect(!LinkGuard.isIPLiteral("example.com"))
        #expect(!LinkGuard.isPublicAddress("example.com"))
    }

    // MARK: GlassKeyFix: the maps are little-endian words in and out

    @Test func glassKeyFixDecodesAndEncodesLittleEndianWords() throws {
        // A 1 x 1 map: the white map's alpha 0x1234, then the black map's 0x5678, little-endian, zlib.
        let raw = Data([0x34, 0x12, 0x78, 0x56])
        let packed = try (raw as NSData).compressed(using: .zlib) as Data
        let (white, black) = try #require(GlassKeyFix.images(packed.base64EncodedString(), w: 1, h: 1))
        let whitePixel = try #require(white.dataProvider?.data as Data?)
        let blackPixel = try #require(black.dataProvider?.data as Data?)
        #expect([UInt8](whitePixel) == [0x34, 0x12, 0x34, 0x12, 0x34, 0x12, 0x34, 0x12])
        #expect([UInt8](blackPixel) == [0, 0, 0, 0, 0, 0, 0x78, 0x56])
    }

    // MARK: LongText: the scan reads the text as a checked collection

    @Test func aLongTextScanCutsAtLineEndsAndKeepsEveryByte() {
        let text = (0..<600).map { "line \($0) of a long message, with a needle at \($0 * 7)" }.joined(separator: "\n")
        let idx = LongTextIndex.build(text, lineage: 1, markdown: false)
        #expect(idx.blockCount > 2)
        #expect(idx.starts.first == 0)
        #expect(idx.starts.last == text.utf8.count)
        #expect(zip(idx.starts, idx.starts.dropFirst()).allSatisfy { $0 < $1 })
        // Each block but the last ends at a newline, and the blocks put together are the text.
        for b in 0..<(idx.blockCount - 1) { #expect((idx.blockString(b) as String).hasSuffix("\n")) }
        #expect((0..<idx.blockCount).map { idx.blockString($0) as String }.joined() == text)
        let found = idx.find("needle at 4193")
        let byteOffset = Array(text.utf8).firstRange(of: Array("needle at 4193".utf8))?.lowerBound
        #expect(found?.lowerBound == byteOffset)
        #expect(idx.u16Offset(utf8: idx.count) == (text as NSString).length)
    }

    @Test func aLongMarkdownFenceAcrossTheCutCarriesTheFence() {
        let code = (0..<200).map { "let value\($0) = \($0) // a line of code" }.joined(separator: "\n")
        let text = "Intro\n\n```swift\n" + code + "\n```\n\nAfter the code.\n"
        let idx = LongTextIndex.build(text, lineage: 1, markdown: true)
        #expect(idx.blockCount > 1)
        #expect(idx.starts.last == text.utf8.count)
        guard case .fence = idx.carry(1) else {
            Issue.record("the second block starts inside the fence, so it carries it: \(idx.carry(1))")
            return
        }
    }

    // MARK: Core Graphics, Core Text and AppKit wrappers

    @Test func coreTextWrappersReadTheOutParameters() {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Hello"))
        let bounds = line.typographicBounds
        #expect(bounds.width > 0)
        #expect(bounds.ascent > 0)
        #expect(line.typographicWidth == bounds.width)
        #expect(line.offset(forStringIndex: 0) == 0)
        #expect(abs(line.offset(forStringIndex: 5) - CGFloat(bounds.width)) < 0.5)
    }

    @Test func pathsWithoutATransformPointer() throws {
        let r = CGRect(x: 1, y: 2, width: 30, height: 20)
        func near(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
        }
        #expect(near(CGPath.roundedRect(r, cornerWidth: 4, cornerHeight: 4).boundingBoxOfPath, r))
        #expect(near(CGPath.rect(r).boundingBoxOfPath, r))
        #expect(near(CGPath.ellipse(in: r).boundingBoxOfPath, r))
        let moved = try #require(CGPath.rect(r).copy(applying: CGAffineTransform(translationX: 5, y: -2)))
        #expect(near(moved.boundingBoxOfPath, r.offsetBy(dx: 5, dy: -2)))
    }

    @Test func anOwnedBitmapGivesBackItsBytes() throws {
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext.ownedBitmap(width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: space,
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.clear(CGRect(x: 0, y: 0, width: 2, height: 1))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        #expect(ctx.bitmapBytes() == [255, 0, 0, 255, 0, 0, 0, 0])
    }

    @Test func aGradientNeedsOneLocationPerColor() {
        let colors = [CGColor(gray: 0, alpha: 1), CGColor(gray: 1, alpha: 1)]
        #expect(CGGradient.checked(colorsSpace: nil, colors: colors, locations: [0, 1]) != nil)
        #expect(CGGradient.checked(colorsSpace: nil, colors: colors, locations: [0]) == nil)
        #expect(CGGradient.checked(colorsSpace: nil, colors: colors, locations: [0, 0.5, 1]) == nil)
    }

    @Test func anOwnedBitmapImageRep() throws {
        let rep = try #require(NSBitmapImageRep.owned(pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4,
                                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                      bytesPerRow: 0, bitsPerPixel: 0))
        #expect(rep.pixelsWide == 3)
        #expect(rep.pixelsHigh == 2)
    }

    @Test func layerBitmapContentsIsOnlyAnImage() throws {
        let layer = CALayer()
        #expect(layer.bitmapContents == nil)
        layer.contents = "not an image" as NSString
        #expect(layer.bitmapContents == nil)
        let ctx = try #require(CGContext.ownedBitmap(width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                                     space: CGColorSpaceCreateDeviceRGB(),
                                                     bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(ctx.makeImage())
        layer.contents = image
        #expect(layer.bitmapContents === image)
    }

    @Test func attributesReadWithoutARangePointer() {
        let s = NSAttributedString(string: "ab", attributes: [.kern: 2])
        #expect(s.attribute(.kern, at: 1) as? Int == 2)
        #expect(s.attributes(at: 0)[.kern] as? Int == 2)
        #expect(s.attribute(.link, at: 0) == nil)
    }

    @Test func associationKeysKeepOneValueEachPerObject() {
        let first = AssociationKey(), second = AssociationKey()
        let object = NSObject()
        first.set(1, on: object)
        second.set("two", on: object)
        #expect(first.value(on: object) as? Int == 1)
        #expect(second.value(on: object) as? String == "two")
        first.set(nil, on: object)
        #expect(first.value(on: object) == nil)
        #expect(second.value(on: object) as? String == "two")
    }

    @Test func checkedWritesFromManyThreadsLandEachInItsOwnElement() {
        var values = [Int](repeating: -1, count: 64)
        values.withUnsafeMutableBufferPointer { out in
            DispatchQueue.concurrentPerform(iterations: 64) { i in
                // SAFETY: the array's storage, lent for this closure, which concurrentPerform does not outlive.
                unsafe out.checkedWrite(i * 2, at: i)
            }
            // SAFETY: as above; an index outside the buffer writes nothing.
            unsafe out.checkedWrite(7, at: 64)
            unsafe out.checkedWrite(7, at: -1)
        }
        #expect(values == (0..<64).map { $0 * 2 })
    }

    @Test func sharedStorageIsBufferIdentity() {
        let a = [1, 2, 3]
        let b = a
        var c = a
        c.append(4) // a copy of its own now
        c.removeLast()
        #expect(a.sharesStorage(with: b))
        #expect(c == a)
        #expect(!a.sharesStorage(with: c))
    }
}
