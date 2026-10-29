import CmuxFuzzSupport
import CoreGraphics
import Foundation
import Testing
@testable import CmuxVNC
@testable import CmuxVNCDemoServer

/// A VNC server is untrusted input (`RFBLimits`). Whatever it sends in the handshake, in
/// rectangles, in cut text or in a colour map gives a typed `RFBError`, a value inside the
/// limits, or a wait for more bytes; never a trap. A rectangle outside the framebuffer, a
/// subrectangle outside its rectangle or tile, a CopyRect source outside the framebuffer and a
/// screen outside the new framebuffer are refused, never clipped, as TigerVNC refuses them.
/// Seeded property tests on CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS).
@Suite struct RFBFuzzTests {
    /// One input of any property, its choices read from `data`.
    static func oneInput(_ data: Data) async throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(4) {
        case 0: try await handshake(&rng)
        case 1: try await rectangles(&rng)
        case 2: try await session(&rng)
        default: try screenLayout(&rng)
        }
    }

    /// The displays found in any frame lie inside it, left to right without overlap, and are
    /// never one (a single display is no layout): the pages a viewer swipes between.
    static func screenLayout(_ rng: inout FuzzRNG) throws {
        let width = 1 + rng.below(1400), height = 1 + rng.below(500)
        let background = 0xFF00_0000 | UInt32(1 + rng.below(0xFF_FFFF))
        var pixels = [UInt32](repeating: background, count: width * height)
        for _ in 0 ..< rng.below(4) {
            let x = rng.below(width), y = rng.below(height)
            let w = 1 + rng.below(width - x), h = 1 + rng.below(height - y)
            let color: UInt32 = rng.oneIn(4) ? 0xFF00_0000 | UInt32(rng.below(0x100_0000)) : 0xFF00_0000
            for row in y ..< y + h {
                for column in x ..< x + w { pixels[row * width + column] = color }
            }
        }
        if rng.oneIn(8) {
            for index in pixels.indices {
                if rng.oneIn(64) { pixels[index] = 0xFF00_0000 }
            }
        }
        let screens = VNCScreenLayout().screens(pixels: pixels, width: width, height: height, rowPixels: width)
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        try FuzzRun.check(screens.count != 1, "one display is no layout")
        try FuzzRun.check(screens.allSatisfy { !$0.isEmpty && bounds.contains($0) }, "displays \(screens) outside \(bounds)")
        try FuzzRun.check(zip(screens, screens.dropFirst()).allSatisfy { $0.maxX <= $1.minX }, "displays \(screens) overlap")
    }

    /// The handshake gives server info inside the limits, or an `RFBError`.
    static func handshake(_ rng: inout FuzzRNG) async throws {
        let credentials = HostileRFB.credentials(&rng)
        var bytes = HostileRFB.handshake(&rng)
        if rng.oneIn(3) { bytes = HostileRFB.mutate(bytes, &rng) }
        let chunk = 1 + rng.below(32)
        let transport = ScriptedTransport(bytes, chunk: chunk)
        let info: VNCServerInfo
        do {
            info = try await RFBHandshake(credentials: credentials).run(reader: RFBReader(transport: transport), transport: transport)
        } catch is RFBError {
            return
        }
        try FuzzRun.check(info.width <= RFBLimits.maxSide && info.height <= RFBLimits.maxSide
            && info.width * info.height <= RFBLimits.maxPixels, "ServerInit \(info.width)x\(info.height) passed the limits")
        try FuzzRun.check([3, 7, 8].contains(info.protocolMinor), "negotiated minor \(info.protocolMinor)")
        try FuzzRun.check([1, 2, 30].contains(info.securityType), "security type \(info.securityType)")
        // An account password never goes out as a VNC password response.
        try FuzzRun.check(credentials.username == nil || info.securityType != 2, "an account signed in with VNC authentication")
    }

    /// Rectangles decode inside the framebuffer, or are refused with an `RFBError`. A pixel
    /// rectangle that decodes (or fails part way) changed no pixel outside itself; every pixel
    /// stays opaque; the dirty region stays inside the framebuffer.
    static func rectangles(_ rng: inout FuzzRNG) async throws {
        let framebuffer = Framebuffer(width: rng.below(49), height: rng.below(49))
        let streams = HostileRFB.Deflaters()
        var headers: [RFBRectangleHeader] = []
        var bytes: [UInt8] = []
        for _ in 0 ..< 1 + rng.below(4) {
            let rectangle = HostileRFB.rectangle(&rng, width: framebuffer.width, height: framebuffer.height, streams: streams)
            headers.append(rectangle.header)
            bytes += rectangle.body
        }
        if rng.oneIn(4) { bytes = HostileRFB.mutate(bytes, &rng) }
        let chunk = 1 + rng.below(64)
        let reader = RFBReader(transport: ScriptedTransport(bytes, chunk: chunk))
        let decoder = RFBRectangleDecoder()
        for header in headers {
            let before = framebuffer.pixels, width = framebuffer.width, height = framebuffer.height
            let isPixelRectangle = HostileRFB.isPixelEncoding(header.encoding)
            var effect: RFBRectangleEffect?
            do {
                effect = try await decoder.decode(header, reader: reader, into: framebuffer)
            } catch is RFBError {
                effect = nil
            }
            try checkFramebuffer(framebuffer)
            if isPixelRectangle {
                try FuzzRun.check(framebuffer.width == width && framebuffer.height == height, "a pixel rectangle resized the framebuffer")
                try FuzzRun.check(HostileRFB.changedOnlyInside(header, before: before, after: framebuffer.pixels, width: width),
                                  "rectangle \(header) changed pixels outside itself")
            }
            guard let effect else { return } // a session ends at its first error; so does this stream
            if isPixelRectangle {
                try FuzzRun.check(header.x + header.width <= width && header.y + header.height <= height,
                                  "rectangle \(header) outside \(width)x\(height) was not refused")
            }
            switch effect {
            case let .cursor(cursor):
                try FuzzRun.check(cursor.width <= RFBLimits.maxCursorSide && cursor.height <= RFBLimits.maxCursorSide
                    && cursor.pixels.count == cursor.width * cursor.height, "cursor \(cursor.width)x\(cursor.height)")
            case let .screens(screens):
                let bounds = CGRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
                try FuzzRun.check(screens.allSatisfy { !$0.frame.isEmpty && bounds.contains($0.frame) },
                                  "screens \(screens) outside \(bounds)")
                try FuzzRun.check(!screens.isEmpty && Set(screens.map(\.id)).count == screens.count,
                                  "screens \(screens) empty or with a repeated id")
            case .drew, .resized, .lastRect:
                break
            }
        }
    }

    /// A whole session over hostile server bytes ends with `.disconnected(RFBError)`, never a
    /// trap and never an untyped error; what it reports on the way stays inside the limits.
    static func session(_ rng: inout FuzzRNG) async throws {
        let width = 1 + rng.below(48), height = 1 + rng.below(48)
        var bytes = rng.oneIn(4) ? HostileRFB.handshake(&rng) : HostileRFB.plainHandshake(width: width, height: height)
        let streams = HostileRFB.Deflaters()
        for _ in 0 ..< 1 + rng.below(6) {
            bytes += HostileRFB.serverMessage(&rng, width: width, height: height, streams: streams)
        }
        if rng.oneIn(4) { bytes = HostileRFB.mutate(bytes, &rng) }
        var encodings: [RFBEncoding]?
        if rng.bool() {
            var chosen: [RFBEncoding] = []
            for encoding in RFBEncoding.allCases {
                if rng.bool() { chosen.append(encoding) }
            }
            encodings = chosen
        }
        let localCursor = rng.bool()
        let credentials = HostileRFB.credentials(&rng)
        let chunk = 1 + rng.below(64)
        try await serve(bytes, chunk: chunk,
                        options: VNCSessionOptions(credentials: credentials, localCursor: localCursor, encodings: encodings))
    }

    /// Runs one client over `server` until the session ends and checks what it reported.
    static func serve(_ server: [UInt8], chunk: Int, options: VNCSessionOptions = VNCSessionOptions()) async throws {
        let client = VNCClient(endpoint: VNCEndpoint(host: "fuzz.invalid", port: 5900), options: options,
                               transport: ScriptedTransport(server, chunk: chunk))
        await client.connect()
        var ended = false
        var reason: RFBError?
        for await event in client.events {
            switch event {
            case let .connected(info):
                try FuzzRun.check(info.width * info.height <= RFBLimits.maxPixels, "connected at \(info.width)x\(info.height)")
            case let .cursor(cursor):
                try FuzzRun.check(cursor.width <= RFBLimits.maxCursorSide && cursor.height <= RFBLimits.maxCursorSide
                    && cursor.pixels.count == cursor.width * cursor.height, "cursor \(cursor.width)x\(cursor.height)")
            case let .screens(screens):
                try FuzzRun.check(screens.allSatisfy { !$0.frame.isEmpty && $0.frame.maxX <= CGFloat(RFBLimits.maxSide)
                    && $0.frame.maxY <= CGFloat(RFBLimits.maxSide) }, "screens \(screens)")
            case let .clipboard(text):
                // ServerCutText is Latin-1: one scalar per byte, at most 16 MB.
                try FuzzRun.check(text.unicodeScalars.allSatisfy { $0.value <= 0xFF } && text.unicodeScalars.count <= 16 << 20,
                                  "clipboard of \(text.unicodeScalars.count) scalars")
            case .bell:
                break
            case let .disconnected(error):
                ended = true
                reason = error
            }
        }
        try FuzzRun.check(ended, "the events ended without a disconnect")
        guard let reason else { throw FuzzError.property("the session ended with no error", location: #fileID) }
        // The scripted transport only throws RFBError: `.transport` would be an untyped error inside the client.
        if case let .transport(detail) = reason { throw FuzzError.property("an untyped error: \(detail)", location: #fileID) }
    }

    static func checkFramebuffer(_ framebuffer: Framebuffer) throws {
        try FuzzRun.check(framebuffer.pixels.count == framebuffer.width * framebuffer.height, "pixel count")
        try FuzzRun.check(framebuffer.width <= RFBLimits.maxSide && framebuffer.height <= RFBLimits.maxSide
            && framebuffer.width * framebuffer.height <= RFBLimits.maxPixels, "framebuffer \(framebuffer.width)x\(framebuffer.height)")
        try FuzzRun.check(framebuffer.pixels.allSatisfy { $0 >> 24 == 0xFF }, "a pixel is not opaque")
        let dirty = framebuffer.takeDirty()
        let bounds = CGRect(x: 0, y: 0, width: framebuffer.width, height: framebuffer.height)
        try FuzzRun.check(dirty.isNull || bounds.contains(dirty), "dirty \(dirty) outside \(bounds)")
    }

    // MARK: Runs

    @Test func handshakeTakesAnyServerBytes() async throws {
        try await FuzzRun("RFB.handshake", seed: 0x2301, iterations: 1_500).forEachAwaiting { rng in
            try await Self.handshake(&rng)
        }
    }

    @Test func rectanglesDecodeInsideOrAreRefused() async throws {
        try await FuzzRun("RFB.rectangles", seed: 0x2302, iterations: 1_500).forEachAwaiting { rng in
            try await Self.rectangles(&rng)
        }
    }

    @Test func sessionsEndWithATypedError() async throws {
        try await FuzzRun("RFB.session", seed: 0x2303, iterations: 600).forEachAwaiting { rng in
            try await Self.session(&rng)
        }
    }

    @Test func serverStreamsTakeAnyBytes() async throws {
        let run = try FuzzRun("RFB.serverBytes", seed: 0x2304, iterations: 1_000)
        let mutator = FuzzMutator(dictionary: HostileRFB.dictionary, maximumCount: 1 << 14)
        try await run.forEachInputAwaiting(run.corpus(seeds: HostileRFB.seedStreams()), mutator: mutator) { data in
            try await Self.serve([UInt8](data), chunk: 7)
        }
    }

    @Test func screenLayoutTakesAnyFrame() throws {
        try FuzzRun("RFB.screenLayout", seed: 0x2306, iterations: 300).forEach { rng in
            try Self.screenLayout(&rng)
        }
    }

    @Test func oneInputTakesAnyBytes() async throws {
        let run = try FuzzRun("RFB.oneInput", seed: 0x2305, iterations: 512)
        // Choice tapes, one per branch: 0 handshake, 1 rectangles, 2 session, 3 screen layout.
        try await run.forEachInputAwaiting(run.corpus(seeds: [Data([0]), Data([1]), Data([2]), Data([3])])) { data in
            try await Self.oneInput(data)
        }
    }
}

/// The out-of-range refusals, one input each (each passed silently, clipped, before them).
struct RFBRefusalTests {
    let opaqueBlack: UInt32 = 0xFF00_0000, red: UInt32 = 0xFFFF_0000, blue: UInt32 = 0xFF00_00FF

    @Test func rreSubrectangleOutsideItsRectangleIsRefused() async {
        let framebuffer = Framebuffer(width: 8, height: 8)
        var body = Bytes()
        body.u32(1)
        body.data += bgrx(blue)
        body.data += bgrx(red)
        body.u16(2); body.u16(2); body.u16(4); body.u16(4) // reaches (6, 6) in a 4x4 rectangle
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 4, height: 4, encoding: 2), body: body.data, into: framebuffer)
        }
        for y in 0 ..< 8 {
            for x in 0 ..< 8 where x >= 4 || y >= 4 {
                #expect(framebuffer.pixels[y * 8 + x] == opaqueBlack, "pixel (\(x), \(y)) outside the rectangle changed")
            }
        }
    }

    @Test func hextileSubrectangleOutsideItsTileIsRefused() async {
        let framebuffer = Framebuffer(width: 8, height: 8)
        // One 4x4 tile: background, one subrectangle of 4x4 at (2, 2).
        let body: [UInt8] = [UInt8(2 | 8)] + bgrx(blue) + [UInt8(1), 0x22, 0x33]
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 4, height: 4, encoding: 5), body: body, into: framebuffer)
        }
        #expect(framebuffer.pixels[5 * 8 + 5] == opaqueBlack)
    }

    @Test func copyRectSourceOutsideTheFramebufferIsRefused() async {
        let framebuffer = Framebuffer(width: 4, height: 4)
        var body = Bytes()
        body.u16(3); body.u16(3)
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 2, height: 2, encoding: 1), body: body.data, into: framebuffer)
        }
    }

    @Test func screenOutsideTheNewFramebufferIsRefused() async {
        let framebuffer = Framebuffer(width: 4, height: 4)
        var body = Bytes()
        body.u8(1); body.u8(0); body.u8(0); body.u8(0)
        body.u32(7)
        body.u16(4); body.u16(0); body.u16(8); body.u16(8) // 4..12 wide in an 8-wide framebuffer
        body.u32(0)
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 8, height: 8, encoding: -308), body: body.data, into: framebuffer)
        }
        #expect(framebuffer.width == 4 && framebuffer.height == 4, "a refused layout resized the framebuffer")
    }

    @Test func aLayoutWithNoScreenIsRefused() async {
        let framebuffer = Framebuffer(width: 4, height: 4)
        var body = Bytes()
        body.u8(0); body.u8(0); body.u8(0); body.u8(0)
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 8, height: 8, encoding: -308), body: body.data, into: framebuffer)
        }
        #expect(framebuffer.width == 4 && framebuffer.height == 4, "a refused layout resized the framebuffer")
    }

    @Test func aScreenListedTwiceIsRefused() async {
        let framebuffer = Framebuffer(width: 4, height: 4)
        var body = Bytes()
        body.u8(2); body.u8(0); body.u8(0); body.u8(0)
        body.u32(1); body.u16(0); body.u16(0); body.u16(4); body.u16(8); body.u32(0)
        body.u32(1); body.u16(4); body.u16(0); body.u16(4); body.u16(8); body.u32(0)
        await #expect(throws: RFBError.self) {
            _ = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 8, height: 8, encoding: -308), body: body.data, into: framebuffer)
        }
        #expect(framebuffer.width == 4 && framebuffer.height == 4, "a refused layout resized the framebuffer")
    }

    @Test func screensInsideTheNewFramebufferAreKept() async throws {
        let framebuffer = Framebuffer(width: 4, height: 4)
        var body = Bytes()
        body.u8(2); body.u8(0); body.u8(0); body.u8(0)
        body.u32(1); body.u16(0); body.u16(0); body.u16(4); body.u16(8); body.u32(0)
        body.u32(2); body.u16(4); body.u16(0); body.u16(4); body.u16(6); body.u32(0)
        let effect = try await decode(RFBRectangleHeader(x: 0, y: 0, width: 8, height: 8, encoding: -308), body: body.data, into: framebuffer)
        #expect(effect == .screens([VNCScreen(id: 1, frame: CGRect(x: 0, y: 0, width: 4, height: 8)),
                                    VNCScreen(id: 2, frame: CGRect(x: 4, y: 0, width: 4, height: 6))]))
        #expect(framebuffer.width == 8 && framebuffer.height == 8)
    }

    @Test func colourMapPastTheMapEndsTheSession() async throws {
        var server = HostileRFB.plainHandshake(width: 4, height: 4)
        var message = Bytes()
        message.u8(1); message.u8(0)
        message.u16(65535); message.u16(2) // entries 65535 and 65536 of a 65536-entry map
        message.data += [UInt8](repeating: 0, count: 12)
        server += message.data
        let client = VNCClient(endpoint: VNCEndpoint(host: "fuzz.invalid", port: 5900), transport: ScriptedTransport(server))
        await client.connect()
        var last: VNCEvent?
        for await event in client.events { last = event }
        guard case let .disconnected(.protocolViolation(detail)?)? = last else {
            Issue.record("expected a protocol violation, got \(String(describing: last))")
            return
        }
        #expect(detail.contains("colour map"))
    }

    @Test func colourMapInsideTheMapIsSkipped() async throws {
        var server = HostileRFB.plainHandshake(width: 4, height: 4)
        var message = Bytes()
        message.u8(1); message.u8(0)
        message.u16(65534); message.u16(2)
        message.data += [UInt8](repeating: 0, count: 12)
        server += message.data
        server += [2] // Bell: read only if the colour map was skipped whole
        let client = VNCClient(endpoint: VNCEndpoint(host: "fuzz.invalid", port: 5900), transport: ScriptedTransport(server))
        await client.connect()
        var events: [VNCEvent] = []
        for await event in client.events { events.append(event) }
        #expect(events.contains(.bell))
        #expect(events.last == .disconnected(.connectionClosed))
    }

    /// A viewer's scroll message carries any Int; abs(Int.min) trapped.
    @Test func scrollOfAnyMagnitudeNeverTraps() async {
        let client = VNCClient(endpoint: VNCEndpoint(host: "fuzz.invalid", port: 5900), transport: ScriptedTransport([]))
        await client.scroll(dx: .min, dy: .min)
        await client.scroll(dx: .max, dy: .max)
        await client.scroll(dx: .min, dy: .max)
    }
}

/// Hostile server bytes, built from a generator's choices: mostly well formed, with lengths,
/// counts and coordinates at and past their limits.
enum HostileRFB {
    /// The Zlib and ZRLE deflate streams of one connection (the decoder keeps one inflater for each).
    final class Deflaters {
        let zlib = Deflater()
        let zrle = Deflater()
    }

    static let dictionary: [Data] = [
        Data("RFB 003.008\n".utf8), Data("RFB 003.003\n".utf8), Data("RFB 003.889\n".utf8),
        Data([0xFF, 0xFF]), Data([0, 0, 0, 0]), Data([0xFF, 0xFF, 0xFF, 0xFF]), Data([0x80, 0, 0, 0]),
        Data([0x40, 0x01]), Data([0x40, 0x00]),
    ] + RFBEncoding.allCases.map { encoding in
        let raw = UInt32(bitPattern: encoding.rawValue)
        return Data([UInt8(raw >> 24), UInt8((raw >> 16) & 0xFF), UInt8((raw >> 8) & 0xFF), UInt8(raw & 0xFF)])
    }

    static func pick<Value>(_ rng: inout FuzzRNG, _ choices: [Value]) -> Value {
        choices[rng.below(choices.count)]
    }

    static func mutate(_ bytes: [UInt8], _ rng: inout FuzzRNG) -> [UInt8] {
        [UInt8](FuzzMutator(dictionary: dictionary).mutate(Data(bytes), using: &rng))
    }

    static func isPixelEncoding(_ raw: Int32) -> Bool {
        guard let encoding = RFBEncoding(rawValue: raw) else { return false }
        return ![.desktopSize, .lastRect, .cursor, .extendedDesktopSize].contains(encoding)
    }

    /// Whether every pixel that changed lies inside `header`'s rectangle.
    static func changedOnlyInside(_ header: RFBRectangleHeader, before: [UInt32], after: [UInt32], width: Int) -> Bool {
        guard before.count == after.count, width > 0 else { return before == after }
        for index in before.indices where before[index] != after[index] {
            let x = index % width, y = index / width
            guard x >= header.x, x < header.x + header.width, y >= header.y, y < header.y + header.height else { return false }
        }
        return true
    }

    static func credentials(_ rng: inout FuzzRNG) -> VNCCredentials {
        let alphabet: [Character] = ["a", "Z", "0", " ", "\u{0}", "é", "€", "🙂"]
        let username = rng.text(alphabet, 80)
        let password = rng.text(alphabet, 80)
        switch rng.below(3) {
        case 0: return VNCCredentials()
        case 1: return VNCCredentials(password: password)
        default: return VNCCredentials(username: username, password: password)
        }
    }

    /// RFB 3.8, security None, ServerInit `width` x `height` in the client's own format.
    static func plainHandshake(width: Int, height: Int) -> [UInt8] {
        var b = Bytes()
        b.data += Array("RFB 003.008\n".utf8)
        b.u8(1); b.u8(1)
        b.u32(0)
        b.data += serverInit(width: width, height: height, name: "fuzz")
        return b.data
    }

    /// A u32 length and up to 64 of its bytes: empty, short, at `limit`, past it, or 4 GB.
    static func lengthPrefixed(_ b: inout Bytes, _ rng: inout FuzzRNG, limit: Int) {
        let short = 1 + rng.below(32)
        let length = pick(&rng, [0, short, limit, limit + 1, Int(UInt32.max)])
        b.u32(length)
        b.data += rng.bytes(count: min(length, 64))
    }

    static func handshake(_ rng: inout FuzzRNG) -> [UInt8] {
        var b = Bytes()
        let minor = pick(&rng, [3, 7, 8, 889, 4, 6, 9])
        if rng.oneIn(10) {
            b.data += rng.bytes(count: 12)
        } else {
            let digits = String(minor)
            b.data += Array("RFB 003.\(String(repeating: "0", count: max(0, 3 - digits.count)) + digits)\n".utf8)
        }
        // The client answers 3.8 to any 3.x from 3.8 up, 3.7 to 3.7 and 3.3 to the rest.
        if minor < 7 {
            let other = Int(truncatingIfNeeded: rng.next() & 0xFFFF_FFFF)
            let type = pick(&rng, [0, 1, 2, 30, 258, other])
            b.u32(type)
            if type == 0 { lengthPrefixed(&b, &rng, limit: 4096) }
        } else {
            let count = pick(&rng, [0, 1, 2, 3, 255])
            b.u8(count)
            if count == 0 { lengthPrefixed(&b, &rng, limit: 4096) }
            for _ in 0 ..< min(count, 4) { b.u8(pick(&rng, [1, 2, 30, 16, 0, 255])) }
        }
        // What the chosen type reads: a VNC challenge, an Apple DH exchange, or nothing.
        switch rng.below(3) {
        case 0:
            b.data += rng.bytes(count: 16)
        case 1:
            b.u16(pick(&rng, [0, 1, 2, 5, 0xFFFF]))
            let length = pick(&rng, [0, 1, 4, 16, 128, 513])
            b.u16(length)
            b.data += rng.bytes(count: min(length, 128)) // prime
            b.data += rng.bytes(count: min(length, 128)) // server key
        default:
            break
        }
        b.u32(pick(&rng, [0, 0, 0, 1]))
        if rng.oneIn(4) { lengthPrefixed(&b, &rng, limit: 4096) }
        let side = 1 + rng.below(64)
        b.u16(pick(&rng, [0, 1, side, 16384, 16385, 0xFFFF]))
        let otherSide = 1 + rng.below(64)
        b.u16(pick(&rng, [0, 1, otherSide, 16384, 16385, 0xFFFF]))
        b.data += rng.oneIn(4) ? rng.bytes(count: 16) : RFBPixelFormat.bgrx.encoded
        lengthPrefixed(&b, &rng, limit: 4096)
        return b.data
    }

    /// A coordinate or a length at the edges of `limit`: 0, at it, just past it, the u16
    /// maximum, or inside.
    static func edge(_ rng: inout FuzzRNG, _ limit: Int) -> Int {
        switch rng.below(6) {
        case 0: 0
        case 1: limit
        case 2: min(limit + 1, 0xFFFF)
        case 3: 0xFFFF
        default: rng.below(limit + 1)
        }
    }

    /// An origin and a length inside `limit` half the time, at its edges otherwise.
    static func span(_ rng: inout FuzzRNG, _ limit: Int) -> (origin: Int, length: Int) {
        if rng.bool() {
            let origin = rng.below(limit + 1)
            return (origin, rng.below(limit - origin + 1))
        }
        let origin = edge(&rng, limit)
        return (origin, edge(&rng, limit))
    }

    /// `count`, or one time in eight fewer (a body cut short).
    static func truncated(_ rng: inout FuzzRNG, _ count: Int) -> Int {
        rng.oneIn(8) ? rng.below(count + 1) : count
    }

    static func pixel(_ rng: inout FuzzRNG) -> [UInt8] {
        rng.bytes(count: 4)
    }

    /// One rectangle header and its body for a `width` x `height` framebuffer.
    static func rectangle(_ rng: inout FuzzRNG, width: Int, height: Int, streams: Deflaters)
        -> (header: RFBRectangleHeader, body: [UInt8]) {
        let unknown = Int32(truncatingIfNeeded: rng.next())
        let encoding = pick(&rng, [0, 1, 2, 5, 6, 16, -223, -224, -239, -308, unknown])
        var header = RFBRectangleHeader(x: 0, y: 0, width: 0, height: 0, encoding: encoding)
        var b = Bytes()
        switch RFBEncoding(rawValue: encoding) {
        case .desktopSize?, .extendedDesktopSize?:
            let w = 1 + rng.below(48), h = 1 + rng.below(48)
            header.width = pick(&rng, [0, w, w, 16384, 16385, 0xFFFF])
            header.height = pick(&rng, [0, h, h, 16385, 0xFFFF])
            header.y = encoding == RFBEncoding.extendedDesktopSize.rawValue ? pick(&rng, [0, 0, 1]) : 0
            if encoding == RFBEncoding.extendedDesktopSize.rawValue {
                let count = pick(&rng, [0, 1, 2, 3, 255])
                b.u8(count); b.u8(0); b.u8(0); b.u8(0)
                for _ in 0 ..< min(count, 4) {
                    b.u32(Int(truncatingIfNeeded: rng.next() & 0xFFFF_FFFF))
                    let columns = span(&rng, min(header.width, 0xFFFF)), rows = span(&rng, min(header.height, 0xFFFF))
                    b.u16(columns.origin); b.u16(rows.origin); b.u16(columns.length); b.u16(rows.length)
                    b.u32(0)
                }
            }
            return (header, b.data)
        case .cursor?:
            let w = 1 + rng.below(16), h = 1 + rng.below(16)
            header.width = pick(&rng, [0, w, w, 256, 257, 0xFFFF])
            header.height = pick(&rng, [0, h, h, 256, 257])
            header.x = rng.below(0x10000)
            header.y = rng.below(0x10000)
            if header.width <= 256, header.height <= 256 {
                let count = header.width * header.height * 4 + (header.width + 7) / 8 * header.height
                let kept = truncated(&rng, count)
                b.data += rng.bytes(count: kept)
            }
            return (header, b.data)
        case .lastRect?:
            return (header, [])
        case nil:
            header.width = rng.below(8)
            header.height = rng.below(8)
            let count = rng.below(32)
            b.data += rng.bytes(count: count)
            return (header, b.data)
        default:
            break
        }
        let columns = span(&rng, width), rows = span(&rng, height)
        header.x = columns.origin
        header.width = columns.length
        header.y = rows.origin
        header.height = rows.length
        // Bodies only for rectangles small enough to fit a 48x48 framebuffer; a larger one is refused unread.
        guard header.width <= 64, header.height <= 64 else { return (header, rng.bytes(count: 16)) }
        let w = header.width, h = header.height
        switch RFBEncoding(rawValue: encoding) {
        case .raw?:
            let count = w * h * 4
            let kept = truncated(&rng, count)
            b.data += rng.bytes(count: kept)
        case .copyRect?:
            let columns = span(&rng, width), rows = span(&rng, height)
            b.u16(columns.origin)
            b.u16(rows.origin)
        case .rre?:
            let some = 1 + rng.below(4)
            let count = pick(&rng, [0, some, some, Int(UInt32.max)])
            b.u32(count)
            b.data += pixel(&rng)
            for _ in 0 ..< min(count, 4) {
                b.data += pixel(&rng)
                let columns = span(&rng, w), rows = span(&rng, h)
                b.u16(columns.origin); b.u16(rows.origin); b.u16(columns.length); b.u16(rows.length)
            }
        case .hextile?:
            b.data += hextile(&rng, width: w, height: h)
        case .zlib?:
            let count = w * h * 4
            let kept = truncated(&rng, count)
            let payload = rng.bytes(count: kept)
            b.data += compressed(&rng, payload, streams.zlib)
        case .zrle?:
            b.data += compressed(&rng, zrleTiles(&rng, width: w, height: h), streams.zrle)
        default:
            break
        }
        return (header, b.data)
    }

    static func hextile(_ rng: inout FuzzRNG, width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        for tileY in stride(from: 0, to: height, by: 16) {
            for tileX in stride(from: 0, to: width, by: 16) {
                let tileWidth = min(16, width - tileX), tileHeight = min(16, height - tileY)
                let mask = rng.byte() & 0x1F
                out.append(mask)
                if mask & 1 != 0 {
                    out += rng.bytes(count: tileWidth * tileHeight * 4)
                    continue
                }
                if mask & 2 != 0 { out += pixel(&rng) }
                if mask & 4 != 0 { out += pixel(&rng) }
                guard mask & 8 != 0 else { continue }
                let count = rng.below(5)
                out.append(UInt8(count))
                for _ in 0 ..< count {
                    if mask & 16 != 0 { out += pixel(&rng) }
                    if rng.oneIn(4) {
                        out += [rng.byte(), rng.byte()]
                    } else {
                        let x = rng.below(tileWidth), y = rng.below(tileHeight)
                        let w = 1 + rng.below(tileWidth - x), h = 1 + rng.below(tileHeight - y)
                        out += [UInt8(x << 4 | y), UInt8((w - 1) << 4 | (h - 1))]
                    }
                }
            }
        }
        return out
    }

    /// The inflated bytes of a ZRLE rectangle: per 64x64 tile a subencoding, its palette and
    /// about as many bytes as the tile needs.
    static func zrleTiles(_ rng: inout FuzzRNG, width: Int, height: Int) -> [UInt8] {
        var out: [UInt8] = []
        for tileY in stride(from: 0, to: height, by: 64) {
            for tileX in stride(from: 0, to: width, by: 64) {
                let pixels = min(64, width - tileX) * min(64, height - tileY)
                let subencoding = pick(&rng, [0, 1, 2, 3, 5, 16, 17, 127, 128, 129, 130, 140, 255])
                out.append(UInt8(subencoding))
                let palette = subencoding >= 130 ? subencoding - 128 : (2 ... 16).contains(subencoding) ? subencoding : 0
                out += rng.bytes(count: palette * 3)
                let rest = rng.below(pixels * 3 + 8)
                out += rng.bytes(count: rest)
            }
        }
        return out
    }

    /// A u32 length (usually right) and the bytes deflated on the connection's stream.
    static func compressed(_ rng: inout FuzzRNG, _ payload: [UInt8], _ deflater: Deflater) -> [UInt8] {
        var data = deflater.deflate(payload)
        if rng.oneIn(8) { data = mutate(data, &rng) }
        var b = Bytes()
        let off = data.count + 1 + rng.below(8)
        b.u32(pick(&rng, [data.count, data.count, data.count, 0, off, RFBLimits.maxCompressedBytes + 1]))
        b.data += data
        return b.data
    }

    /// One server-to-client message after the handshake.
    static func serverMessage(_ rng: inout FuzzRNG, width: Int, height: Int, streams: Deflaters) -> [UInt8] {
        var b = Bytes()
        switch rng.below(7) {
        case 0, 1:
            b.u8(0); b.u8(0)
            let count = 1 + rng.below(4)
            let untilLastRect = rng.oneIn(4)
            b.u16(untilLastRect ? 0xFFFF : count)
            for _ in 0 ..< count {
                let drawn = rectangle(&rng, width: width, height: height, streams: streams)
                let header = drawn.header
                b.u16(header.x); b.u16(header.y); b.u16(header.width); b.u16(header.height)
                b.s32(header.encoding)
                b.data += drawn.body
            }
            if untilLastRect {
                b.u16(0); b.u16(0); b.u16(0); b.u16(0)
                b.s32(RFBEncoding.lastRect.rawValue)
            }
        case 2:
            b.u8(1); b.u8(0)
            let some = rng.below(256)
            b.u16(pick(&rng, [0, some, 65535]))
            let few = 1 + rng.below(8)
            let count = pick(&rng, [0, few, few, 0xFFFF])
            b.u16(count)
            b.data += rng.bytes(count: min(count, 16) * 6)
        case 3:
            b.u8(2)
        case 4:
            b.u8(3); b.u8(0); b.u8(0); b.u8(0)
            let short = rng.below(65)
            let length = pick(&rng, [0, short, short, (16 << 20) + 1, Int(UInt32.max)])
            b.u32(length)
            b.data += rng.bytes(count: min(length, 64))
        case 5:
            b.u8(4 + rng.below(252))
        default:
            let count = rng.below(32)
            b.data += rng.bytes(count: count)
        }
        return b.data
    }

    /// Well-formed sessions for the byte-level run: every message kind once.
    static func seedStreams() -> [Data] {
        var raw = Bytes()
        raw.u8(0); raw.u8(0); raw.u16(1)
        raw.u16(0); raw.u16(0); raw.u16(2); raw.u16(1); raw.s32(0)
        raw.data += bgrx(0xFFFF_0000) + bgrx(0xFF00_00FF)
        var zrle = Bytes()
        let tile = [UInt8(1)] + cpixel(0xFF00_FF00)
        let deflated = Deflater().deflate(tile)
        zrle.u8(0); zrle.u8(0); zrle.u16(1)
        zrle.u16(0); zrle.u16(0); zrle.u16(4); zrle.u16(4); zrle.s32(16)
        zrle.u32(deflated.count)
        zrle.data += deflated
        var others = Bytes()
        others.u8(2)                                           // Bell
        others.u8(3); others.u8(0); others.u8(0); others.u8(0) // ServerCutText
        others.u32(5)
        others.data += Array("h\u{E9}llo".unicodeScalars.map { UInt8($0.value) })
        others.u8(1); others.u8(0); others.u16(0); others.u16(1) // SetColourMapEntries
        others.data += [UInt8](repeating: 0x7F, count: 6)
        var hextile = Bytes()
        hextile.u8(0); hextile.u8(0); hextile.u16(2)
        hextile.u16(0); hextile.u16(0); hextile.u16(4); hextile.u16(4); hextile.s32(5)
        hextile.data += [UInt8(2 | 8)] + bgrx(0xFF00_00FF) + [UInt8(1), 0x11, 0x11]
        hextile.u16(0); hextile.u16(0); hextile.u16(4); hextile.u16(4); hextile.s32(-308)
        hextile.data += [1, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 4, 0, 4, 0, 0, 0, 0]
        let base = plainHandshake(width: 4, height: 4)
        return [base + raw.data, base + zrle.data, base + others.data, base + hextile.data].map { Data($0) }
    }
}
