@testable import CmuxNextControl
import Darwin
import Foundation
import MachO
import Testing

/// A hang sample's frame never takes a `dladdr` name that does not hold its address: in the
/// every-action sweep's macOS 27 shards (m27-s2, `column.moveLeft`, stress), the top frame read
/// `cmux DEV.debug.dylib _ZN5swift28swift_Concurrency_fatalErrorEjPKcz + 43120`, an unnamed Swift
/// function far past that tiny symbol, which read as a crash. The frame keeps its image and offset.
struct StackSymbolicatorStartsTests {
    /// The sample's shape: the exported symbol at 0x4_0000, functions every few hundred bytes after
    /// it (the stripped local ones), the sampled address 43,120 bytes past the symbol.
    static let symbolOffset: UInt = 0x4_0000
    static let starts = FunctionStarts(offsets: [0x1000, symbolOffset, symbolOffset + 0x80, symbolOffset + 0x2_000,
                                                 symbolOffset + 43_000, symbolOffset + 50_000])

    @Test func aNameFromFarBeforeTheAddressIsDroppedForTheImageOffset() {
        let address: UInt = 0x1_2340_0000 + Self.symbolOffset + 43_120
        let frame = StackSymbolicator.frame(address: address, lookup: address - 1, image: "cmux DEV.debug.dylib",
                                            imageOffset: Self.symbolOffset + 43_120,
                                            symbol: "_ZN5swift28swift_Concurrency_fatalErrorEjPKcz",
                                            symbolOffset: Self.symbolOffset, starts: Self.starts)
        #expect(frame.symbol == nil, "\(frame.description)")
        #expect(frame.description == "cmux DEV.debug.dylib +0x" + String(Self.symbolOffset + 43_120, radix: 16))
    }

    @Test func aNameThatHoldsTheAddressStays() {
        let frame = StackSymbolicator.frame(address: 0x9_0000 + Self.symbolOffset + 0x10, lookup: 0x9_0000 + Self.symbolOffset + 0xF,
                                            image: "libswiftCore.dylib", imageOffset: Self.symbolOffset + 0x10,
                                            symbol: "swift_retain", symbolOffset: Self.symbolOffset, starts: Self.starts)
        #expect(frame.description == "libswiftCore.dylib swift_retain + 16")
    }

    @Test func noStartsTableKeepsTheName() {
        let frame = StackSymbolicator.frame(address: 1, lookup: 1, image: "x", imageOffset: Self.symbolOffset + 43_120,
                                            symbol: "f", symbolOffset: Self.symbolOffset, starts: nil)
        #expect(frame.symbol == "f")
    }

    @Test func theStartsTableDecodesAndALiveImageHasOne() throws {
        // ULEB128 deltas 0x1000, 0x40, 0x200 (two bytes: 0x80 0x04), then the zero end.
        let bytes: [UInt8] = [0x80, 0x20, 0x40, 0x80, 0x04, 0x00, 0x7F]
        let decoded = bytes.withUnsafeBytes { FunctionStarts.decode($0, textOffset: 0) }
        #expect(decoded.offsets == [0x1000, 0x1040, 0x1240])
        var info = Dl_info()
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_retain"))
        #expect(dladdr(symbol, &info) != 0)
        let header = try #require(info.dli_fbase)
        let live = try #require(FunctionStarts.read(header: UnsafeRawPointer(header)))
        #expect(!live.offsets.isEmpty)
        #expect(live.offsets == live.offsets.sorted())
        let retain = UInt(bitPattern: symbol) - UInt(bitPattern: header)
        #expect(live.offsets.contains(retain), "swift_retain is a function start of its image")
    }
}

/// A hang record's JSON carries `frame_details` beside `frames`: per frame its image, image UUID,
/// offset from the image header and the symbol or null, so a reader that distrusts a name (the
/// every-action sweep, the dSYM step) resolves the frame by UUID and offset.
struct HangRecordFrameDetailsTests {
    @Test func aNamedFrameStillCarriesItsImageUUIDAndOffset() throws {
        var info = Dl_info()
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swift_retain"))
        #expect(dladdr(symbol, &info) != 0)
        let header = try #require(info.dli_fbase)
        let base = UInt(bitPattern: header)
        let address = UInt(bitPattern: symbol)
        let record = HangRecord(sequence: 1, startUptimeNanos: 0, duration: .milliseconds(30), cpu: .milliseconds(30),
                                addresses: [address])
        let details = try #require(record.json.objectValue?["frame_details"]?.arrayValue?.first?.objectValue)
        #expect(details["image_offset"]?.doubleValue == Double(address - base))
        let uuid = try #require(details["image_uuid"]?.stringValue)
        #expect(UUID(uuidString: uuid) != nil)
        #expect(details["symbol"]?.stringValue == "swift_retain")
        #expect(details["image"]?.stringValue?.hasPrefix("libswiftCore") == true)
    }
}
