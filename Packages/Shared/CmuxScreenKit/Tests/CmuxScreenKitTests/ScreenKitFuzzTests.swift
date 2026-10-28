import CmuxFuzzSupport
@testable import CmuxScreenKit
import CoreGraphics
import Foundation
import Observation
import Testing

/// What reaches a screen session from the other side is untrusted: the frames of a VNC
/// server, the viewer's input frames on the stream's data channel, the host's display
/// frames, and pairing links. None of them traps; a session over any server bytes ends
/// failed with a message, and what it reported on the way stays inside the RFB limits.
/// Seeded property tests on CmuxFuzzSupport (long mode: CMUX_FUZZ_SECONDS).
@MainActor
@Suite struct ScreenKitFuzzTests {
    /// The largest framebuffer side a server may set (`RFBLimits.maxSide`).
    static let maxSide: CGFloat = 16384

    /// One input of any property, its choices read from `data`.
    static func oneInput(_ data: Data) async throws {
        var rng = FuzzRNG(replaying: data)
        switch rng.below(3) {
        case 0: try await serverFrames(&rng)
        case 1: try await viewerInput(Data(HostileFrames.json(&rng).utf8))
        default: try pairingLink(Data(HostileFrames.link(&rng).utf8))
        }
    }

    /// A session over hostile server bytes ends failed, with a message, and every frame,
    /// cursor and screen layout it handed out lies inside a framebuffer the server set.
    static func serverFrames(_ rng: inout FuzzRNG) async throws {
        var (server, sizes) = HostileFrames.server(&rng)
        if rng.oneIn(4) {
            // Mutated bytes may set any framebuffer: only the limits bound it.
            server = [UInt8](FuzzMutator().mutate(Data(server), using: &rng))
            sizes = [CGSize(width: maxSide, height: maxSide)]
        }
        let chunk = 1 + rng.below(64)
        let localCursor = rng.bool()
        try await session(over: server, chunk: chunk, localCursor: localCursor, framebuffers: sizes)
    }

    /// `framebuffers`: every framebuffer size the server's bytes set (ServerInit, DesktopSize,
    /// ExtendedDesktopSize).
    static func session(over server: [UInt8], chunk: Int, localCursor: Bool, framebuffers: [CGSize]) async throws {
        let seen = Seen()
        let session = ScreenSession(title: "Fuzz", endpoint: VNCEndpoint(host: "fuzz.invalid", port: 5900),
                                    preferences: ScreenPreferences(localCursor: localCursor),
                                    transport: { ScriptedServer(server, chunk: chunk) })
        session.onFrame = { frame in seen.frames.append(CGSize(width: frame.width, height: frame.height)) }
        session.onCursor = { cursor in seen.cursors.append(cursor) }
        session.onScreens = { screens in seen.layouts.append(screens) }
        defer { session.close() }
        session.connect()
        await ended(session)
        guard case let .failed(message, _) = session.phase else {
            throw FuzzError.property("the session ended \(session.phase), not failed", location: #fileID)
        }
        try FuzzRun.check(!message.isEmpty, "a failure with no message")
        func fits(_ size: CGSize) -> Bool {
            framebuffers.contains { size.width <= $0.width && size.height <= $0.height }
        }
        try FuzzRun.check(seen.frames.allSatisfy { $0.width > 0 && $0.height > 0 && fits($0) },
                          "frames \(seen.frames) larger than the framebuffers \(framebuffers)")
        try FuzzRun.check(session.frameSize == .zero || fits(session.frameSize), "frame size \(session.frameSize)")
        try FuzzRun.check(seen.cursors.allSatisfy { $0.width <= 256 && $0.height <= 256 && $0.pixels.count == $0.width * $0.height },
                          "a cursor past 256x256")
        // A layout lies inside one framebuffer the server set: its screens are inside the
        // ExtendedDesktopSize that carried them.
        try FuzzRun.check(seen.layouts.allSatisfy { layout in
            layout.allSatisfy { !$0.isEmpty && $0.minX >= 0 && $0.minY >= 0 }
                && fits(CGSize(width: layout.map(\.maxX).max() ?? 0, height: layout.map(\.maxY).max() ?? 0))
        }, "layouts \(seen.layouts) outside the framebuffers \(framebuffers)")
    }

    /// A viewer's input frame (JSON on the data channel) points inside the display it is for,
    /// converts to integer pixels, and turns into RFB input, whatever its numbers.
    static func viewerInput(_ data: Data) async throws {
        guard let input = try? JSONDecoder().decode(ScreenInput.self, from: data) else { return }
        let display = CGRect(x: 1920, y: 0, width: 1024, height: 768)
        let point = input.location(in: display)
        // The last pixel is maxX - 1: maxX is the first column of the display to the right.
        try FuzzRun.check(point.x.isFinite && point.y.isFinite && point.x >= display.minX && point.x < display.maxX
            && point.y >= display.minY && point.y < display.maxY, "\(input) points at \(point), outside \(display)")
        try FuzzRun.check(input.location(in: .zero) == .zero, "\(input) points outside an empty display")
        let pixel = input.pixel(in: display)
        _ = input.wheel
        let client = VNCClient(endpoint: VNCEndpoint(host: "fuzz.invalid", port: 5900), transport: ScriptedServer([], chunk: 1))
        await client.pointer(x: pixel.x, y: pixel.y, buttons: VNCButtons(rawValue: input.b ?? 0))
        await client.scroll(dx: input.dx ?? 0, dy: input.dy ?? 0)
        if let keysym = input.k {
            await client.key(VNCKeysym(rawValue: keysym), down: input.d ?? true)
            await client.chord((input.m ?? []).map(VNCKeysym.init(rawValue:)), VNCKeysym(rawValue: keysym))
        }
        if let text = input.s { await client.type(text) }
    }

    /// The host's display frame reports displays the viewer can show and select, or none; a
    /// pairing link parses into a well-formed pairing or none.
    static func pairingLink(_ data: Data) throws {
        if let message = try? JSONDecoder().decode(ScreenHostMessage.self, from: data) {
            let displays = ScreenSession.streamDisplays(from: message)
            let side = CGFloat(ScreenSession.maxDisplaySide)
            try FuzzRun.check(displays.sizes.allSatisfy { $0.width >= 1 && $0.height >= 1 && $0.width <= side && $0.height <= side },
                              "display sizes \(displays.sizes)")
            try FuzzRun.check(displays.sizes.indices.contains(displays.current) || displays.current == 0,
                              "current display \(displays.current) of \(displays.sizes.count)")
            _ = displays.current + 1 // the toolbar's "Display N"
        }
        guard let text = String(data: data, encoding: .utf8), let url = URL(string: text),
              let pairing = VNCPairing(link: url) else { return }
        try FuzzRun.check(pairing.signal.scheme == "https", "signal \(pairing.signal)")
        try FuzzRun.check(pairing.room.count == 32 && pairing.room.allSatisfy(\.isHexDigit), "room \(pairing.room)")
        try FuzzRun.check((32 ... 128).contains(pairing.secret.count), "secret of \(pairing.secret.count)")
        try FuzzRun.check(["vnc", "stream"].contains(pairing.kind), "kind \(pairing.kind)")
        _ = pairing.link
    }

    /// Waits until `session` has failed or ended.
    static func ended(_ session: ScreenSession) async {
        while !isOver(session.phase) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                withObservationTracking {
                    _ = session.phase
                } onChange: {
                    continuation.resume()
                }
            }
        }
    }

    static func isOver(_ phase: ScreenSession.Phase) -> Bool {
        switch phase {
        case .failed, .ended: true
        case .connecting, .connected: false
        }
    }

    // MARK: Runs

    @Test func sessionsOverAnyServerFramesFail() async throws {
        try await FuzzRun("ScreenKit.serverFrames", seed: 0x2311, iterations: 300).forEachAwaiting { rng in
            try await Self.serverFrames(&rng)
        }
    }

    @Test func viewerInputTakesAnyJSON() async throws {
        let run = try FuzzRun("ScreenKit.viewerInput", seed: 0x2312, iterations: 2_000)
        let mutator = FuzzMutator(dictionary: HostileFrames.jsonTokens)
        try await run.forEachInputAwaiting(run.corpus(seeds: HostileFrames.inputSeeds()), mutator: mutator) { data in
            try await Self.viewerInput(data)
        }
    }

    @Test func pairingLinksAndHostFramesTakeAnyText() throws {
        let run = try FuzzRun("ScreenKit.pairingLink", seed: 0x2313, iterations: 2_000)
        let seeds = [VNCPairing.generate(name: "Mac", kind: "stream").link.absoluteString,
                     VNCPairing.generate(name: "Büro 🙂").link.absoluteString,
                     #"{"t":"displays","displays":[{"w":1920,"h":1080},{"w":-1,"h":99999999999}],"current":7,"name":"Mac"}"#]
        let mutator = FuzzMutator(dictionary: HostileFrames.jsonTokens + HostileFrames.linkTokens)
        try run.forEachInput(run.corpus(seeds: seeds.map { Data($0.utf8) }), mutator: mutator) { data in
            try Self.pairingLink(data)
        }
    }

    @Test func oneInputTakesAnyBytes() async throws {
        let run = try FuzzRun("ScreenKit.oneInput", seed: 0x2314, iterations: 256)
        // Choice tapes, one per branch: 0 server frames, 1 viewer input, 2 pairing link.
        try await run.forEachInputAwaiting(run.corpus(seeds: [Data([0]), Data([1]), Data([2])])) { data in
            try await Self.oneInput(data)
        }
    }

    /// The trap a viewer could set off: a coordinate far past 0...1 overflowed the pixel conversion.
    @Test func inputPastTheDisplayPointsAtItsEdge() throws {
        let display = CGRect(x: 1920, y: 0, width: 1024, height: 768)
        let far = try JSONDecoder().decode(ScreenInput.self, from: Data(#"{"t":"move","x":1e300,"y":-1e300}"#.utf8))
        #expect(far.location(in: display) == CGPoint(x: display.maxX - 1, y: display.minY))
        let inside = ScreenInput(t: "move", x: 0.5, y: 0.25)
        #expect(inside.location(in: display) == CGPoint(x: 1920 + 512, y: 192))
        let scroll = ScreenInput(t: "scroll", dx: .min, dy: .max)
        #expect(scroll.wheel.dx == .min && scroll.wheel.dy == .max)
    }

    /// The trap a host could set off: a current display of Int.max overflowed the toolbar's
    /// "Display N"; a negative size reached the display menu.
    @Test func hostDisplayFramesReportOnlyDisplaysTheViewerCanSelect() throws {
        func displays(_ json: String) throws -> (sizes: [CGSize], current: Int) {
            try ScreenSession.streamDisplays(from: JSONDecoder().decode(ScreenHostMessage.self, from: Data(json.utf8)))
        }
        let two = try displays(#"{"t":"displays","displays":[{"w":1920,"h":1080},{"w":1280,"h":800}],"current":1}"#)
        #expect(two.sizes == [CGSize(width: 1920, height: 1080), CGSize(width: 1280, height: 800)] && two.current == 1)
        let far = try displays(#"{"t":"displays","displays":[{"w":1920,"h":1080}],"current":9223372036854775807}"#)
        #expect(far.sizes.count == 1 && far.current == 0)
        let negative = try displays(#"{"t":"displays","displays":[{"w":1920,"h":1080},{"w":-1,"h":800}],"current":1}"#)
        #expect(negative.sizes.isEmpty && negative.current == 0)
        let huge = try displays(#"{"t":"displays","displays":[{"w":16385,"h":1080}],"current":0}"#)
        #expect(huge.sizes.isEmpty)
    }
}

/// What a session handed out, kept for the checks after it ends.
@MainActor
final class Seen {
    var frames: [CGSize] = []
    var cursors: [VNCCursor] = []
    var layouts: [[CGRect]] = []
}

/// A scripted VNC server: its bytes in chunks of `chunk`, then the end of the stream.
// crash-allow: `pending` is read and written only while `lock` is held.
final class ScriptedServer: RFBTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var pending: ArraySlice<UInt8>
    private let chunk: Int

    init(_ bytes: [UInt8], chunk: Int) {
        pending = bytes[...]
        self.chunk = max(chunk, 1)
    }

    func open() async throws {}

    func receive() async throws -> [UInt8] {
        try lock.withLock {
            guard !pending.isEmpty else { throw RFBError.connectionClosed }
            let next = pending.prefix(chunk)
            pending = pending.dropFirst(next.count)
            return Array(next)
        }
    }

    func send(_ bytes: [UInt8]) async throws {}

    func close() {}
}

/// Hostile frames, built from a generator's choices.
enum HostileFrames {
    static let jsonTokens: [Data] = [
        "\"t\":", "\"move\"", "\"scroll\"", "\"key\"", "\"chord\"", "\"text\"", "\"display\"", "\"bye\"",
        "\"x\":", "\"y\":", "\"dx\":", "\"dy\":", "\"k\":", "\"m\":", "\"s\":", "\"i\":", "\"b\":", "\"d\":",
        "1e308", "-1e308", "1e-320", "-0", "9223372036854775807", "-9223372036854775808", "4294967295", "255", "256",
        "null", "true", "[", "]", "{", "}", ",", "\"\\u0000\"", "\"\\ud83d\\ude42\"",
    ].map { Data($0.utf8) }

    static let linkTokens: [Data] = [
        "cmux-vnc://pair?", "signal=https://", "&room=", "&secret=", "&name=", "&kind=stream", "%", "%00", "%F0%9F",
        "0123456789abcdef0123456789abcdef", "\u{FF10}", "#", "?", "&",
    ].map { Data($0.utf8) }

    static func inputSeeds() -> [Data] {
        [
            #"{"t":"move","x":0.5,"y":0.5,"b":1}"#,
            #"{"t":"scroll","x":0.1,"y":0.9,"dx":-3,"dy":4}"#,
            #"{"t":"key","k":65293,"d":true}"#,
            #"{"t":"chord","k":99,"m":[65511,65505]}"#,
            #"{"t":"text","s":"héllo 🙂"}"#,
            #"{"t":"display","i":1}"#,
            #"{"t":"refresh"}"#,
        ].map { Data($0.utf8) }
    }

    static func pick<Value>(_ rng: inout FuzzRNG, _ choices: [Value]) -> Value {
        choices[rng.below(choices.count)]
    }

    /// A viewer input frame with numbers at and past every limit.
    static func json(_ rng: inout FuzzRNG) -> String {
        let numbers = ["0", "0.5", "1", "-1", "2", "1e300", "-1e300", "9223372036854775807", "-9223372036854775808", "255", "256"]
        let type = pick(&rng, ["move", "scroll", "key", "chord", "text", "display", "refresh", "x"])
        var fields = ["\"t\":\"\(type)\""]
        for key in ["x", "y", "dx", "dy", "k", "b", "i"] {
            guard rng.bool() else { continue }
            let number = pick(&rng, numbers)
            fields.append("\"\(key)\":\(number)")
        }
        if rng.bool() {
            let first = pick(&rng, numbers), second = pick(&rng, numbers)
            fields.append("\"m\":[\(first),\(second)]")
        }
        if rng.bool() {
            let text = rng.text(["a", "é", "🙂", " ", "\\"], 16)
            fields.append("\"s\":\"\(text)\"")
        }
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// A pairing link with each part right, wrong or missing.
    static func link(_ rng: inout FuzzRNG) -> String {
        let hex: [Character] = Array("0123456789abcdefABCDEF\u{FF10}g")
        let roomLength = pick(&rng, [31, 32, 32, 33])
        var room = ""
        for _ in 0 ..< roomLength { room.append(hex[rng.below(hex.count)]) }
        let secretLength = pick(&rng, [0, 31, 32, 64, 128, 129])
        let secret = String(repeating: "s", count: secretLength)
        let signal = pick(&rng, ["https://signal.example", "http://signal.example", "https://", "javascript:alert(1)", "%%"])
        let kind = pick(&rng, ["stream", "vnc", "", "other"])
        return "cmux-vnc://pair?signal=\(signal)&room=\(room)&secret=\(secret)&name=Mac&kind=\(kind)"
    }

    /// RFB 3.8 with no security, a small framebuffer, then server messages with lengths,
    /// counts and rectangles at and past their limits; with every framebuffer size the bytes set.
    static func server(_ rng: inout FuzzRNG) -> (bytes: [UInt8], framebuffers: [CGSize]) {
        var out = Wire()
        out.bytes += Array("RFB 003.008\n".utf8)
        out.u8(1); out.u8(1)
        out.u32(0)
        let side = 1 + rng.below(32), otherSide = 1 + rng.below(32)
        let width = pick(&rng, [side, side, 0, 16384]), height = pick(&rng, [otherSide, otherSide, 0, 16385])
        out.u16(width); out.u16(height)
        var framebuffers = [CGSize(width: width, height: height)]
        out.bytes += [32, 24, 0, 1, 0, 255, 0, 255, 0, 255, 16, 8, 0, 0, 0, 0]
        out.u32(4)
        out.bytes += Array("fuzz".utf8)
        for _ in 0 ..< 1 + rng.below(5) {
            switch rng.below(5) {
            case 0, 1:
                out.u8(0); out.u8(0)
                let count = 1 + rng.below(3)
                out.u16(count)
                for _ in 0 ..< count {
                    if let size = rectangle(&rng, into: &out, width: width, height: height) { framebuffers.append(size) }
                }
            case 2:
                out.u8(2)
            case 3:
                out.u8(3); out.u8(0); out.u8(0); out.u8(0)
                let short = rng.below(48)
                let length = pick(&rng, [short, short, (16 << 20) + 1])
                out.u32(length)
                out.bytes += rng.bytes(count: min(length, 48))
            default:
                out.u8(1); out.u8(0)
                let first = pick(&rng, [0, 65535])
                let count = pick(&rng, [1, 2])
                out.u16(first); out.u16(count)
                out.bytes += rng.bytes(count: 6 * count)
            }
        }
        return (out.bytes, framebuffers)
    }

    /// One rectangle; returns the framebuffer size it sets, for DesktopSize and ExtendedDesktopSize.
    static func rectangle(_ rng: inout FuzzRNG, into out: inout Wire, width: Int, height: Int) -> CGSize? {
        let encoding = pick(&rng, [0, 1, 2, -223, -224, -239, -308])
        let x = rng.below(width + 2), y = rng.below(height + 2)
        let w = rng.below(width + 2), h = rng.below(height + 2)
        out.u16(x); out.u16(y); out.u16(w); out.u16(h)
        out.u32(Int(UInt32(bitPattern: Int32(encoding))))
        switch encoding {
        case 0:
            out.bytes += rng.bytes(count: min(w * h, 64 * 64) * 4)
        case 1:
            let sourceX = rng.below(width + 2), sourceY = rng.below(height + 2)
            out.u16(sourceX); out.u16(sourceY)
        case 2:
            out.u32(1)
            out.bytes += rng.bytes(count: 8)
            let subX = rng.below(w + 2), subY = rng.below(h + 2), subW = rng.below(w + 2), subH = rng.below(h + 2)
            out.u16(subX); out.u16(subY); out.u16(subW); out.u16(subH)
        case -239:
            out.bytes += rng.bytes(count: min(w * h * 4 + (w + 7) / 8 * h, 1 << 16))
        case -308:
            let count = rng.below(4)
            out.u8(count); out.u8(0); out.u8(0); out.u8(0)
            for id in 0 ..< count {
                out.u32(id)
                let screenX = rng.below(w + 2), screenY = rng.below(h + 2), screenW = rng.below(w + 2), screenH = rng.below(h + 2)
                out.u16(screenX); out.u16(screenY); out.u16(screenW); out.u16(screenH)
                out.u32(0)
            }
        default:
            break
        }
        return encoding == -223 || encoding == -308 ? CGSize(width: w, height: h) : nil
    }

    /// Big-endian wire bytes.
    struct Wire {
        var bytes: [UInt8] = []
        mutating func u8(_ value: Int) { bytes.append(UInt8(truncatingIfNeeded: value)) }
        mutating func u16(_ value: Int) { bytes += [UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)] }
        mutating func u32(_ value: Int) {
            bytes += [UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                      UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)]
        }
    }
}
