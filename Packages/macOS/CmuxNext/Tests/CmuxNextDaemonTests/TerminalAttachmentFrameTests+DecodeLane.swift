import CmuxNextCompat
@testable import CmuxNextDaemon
import Foundation
import Testing

extension TerminalAttachmentFrameTests {
    /// An attach connection's reader only routes: a snapshot or a replay always decodes on the
    /// connection's decode lane, a small output inline while the lane is idle, and an output behind a snapshot still
    /// reaches the view after it.
    @Suite(.serialized, .timeLimit(.minutes(1))) struct DecodeLaneRouting {
        typealias FakeDaemon = ReplyEventOrderTests.FakeDaemon

        /// One decoded attach line and whether it decoded on the reader thread.
        struct Decoded: Equatable, Sendable {
            var event: TerminalChannelEvent
            var onReader: Bool
        }

        private static let surface = SurfaceID(rawValue: 3)

        private static func output(_ text: String) -> String {
            #"{"event":"output","surface":3,"data":"\#(Data(text.utf8).base64EncodedString())"}"#
        }

        /// A `history` chunk compressed as the host sends it: raw DEFLATE (`NSData`'s zlib is COMPRESSION_ZLIB).
        private static func history(_ raw: Data) throws -> String {
            let compressed = try (raw as NSData).compressed(using: .zlib) as Data
            return #"{"event":"snapshot","surface":3,"phase":"history","generation":1,"offset":0,"version":1,"#
                + #""compression":"deflate","raw_bytes":\#(raw.count),"data":"\#(compressed.base64EncodedString())"}"#
        }

        @Test func bulkEventsAndLargeLinesAreHeavyAndSmallOutputIsLight() {
            let small = Data(Self.output("a").utf8)
            #expect(TerminalAttachment.eventWeight(name: "output", line: small) == .light)
            #expect(TerminalAttachment.eventWeight(name: "scroll-changed", line: small) == .light)
            for name in ["snapshot", "vt-state", "resized"] {
                #expect(TerminalAttachment.eventWeight(name: name, line: small) == .heavy,
                        "\(name) decodes on the reader")
            }
            let large = Data(count: DecodeLane.lightLineLimit + 1)
            #expect(TerminalAttachment.eventWeight(name: "output", line: large) == .heavy)
        }

        /// Output, a 4 MiB history chunk, then output: the first output decodes inline on the idle lane, the history
        /// inflates off the reader, and the output after it queues behind it, in wire order.
        @Test func aHistoryChunkInflatesOffTheReaderAndKeepsTheStreamsOrder() async throws {
            let daemon = try FakeDaemon()
            let transport = try LineTransport(path: daemon.path, role: .terminalAttach, stats: nil)
            try daemon.accept()
            defer { transport.close() }
            let decoded = Mutex<[Decoded]>([])
            let (arrivals, arrived) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
            let decoder = transport.decoder
            let weigh = EventDispatch { name, line in TerminalAttachment.eventWeight(name: name, line: line) }
            transport.start(dispatch: weigh,
                            onEvent: { name, line, _ in
                                let onReader = DecodeLane.isReaderThread
                                if let line = TerminalAttachment.decodeAttachLine(name: name, line: line,
                                                                                   surface: Self.surface, decoder: decoder) {
                                    let entry = Decoded(event: line.event, onReader: onReader)
                                    decoded.withLock { $0.append(entry) }
                                }
                                arrived.yield()
                            },
                            onClose: { _ in })

            let raw = Data((0..<(4 << 20)).map { UInt8(truncatingIfNeeded: $0 % 251) })
            daemon.write([Self.output("a"), try Self.history(raw), Self.output("b")])
            var seen = 0
            for await _ in arrivals {
                seen += 1
                if seen == 3 { break }
            }

            let lines = decoded.withLock { $0 }
            #expect(lines.count == 3)
            guard lines.count == 3 else { return }
            #expect(lines[0] == Decoded(event: .output(Data("a".utf8), colors: nil), onReader: true),
                    "a small output on an idle lane hopped off the reader")
            guard case .snapshot(let frame) = lines[1].event else {
                Issue.record("the second line is \(lines[1].event)")
                return
            }
            #expect(frame.phase == .history && frame.data == raw)
            #expect(!lines[1].onReader, "the history chunk inflated on the reader")
            #expect(lines[2] == Decoded(event: .output(Data("b".utf8), colors: nil), onReader: false),
                    "the output after the history overtook it")
        }
    }
}
