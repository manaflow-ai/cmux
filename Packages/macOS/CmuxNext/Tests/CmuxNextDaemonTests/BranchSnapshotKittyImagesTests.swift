import Foundation
import Testing
@testable import CmuxNextDaemon

/// A relaunch attaches each restored terminal again, and since #38776 the
/// GHOSTSNP snapshot alone carries its Kitty images: KITTY_IMAGE_STORAGE
/// (tag 8) before READY with the images and their placements, one
/// KITTY_IMAGE_PAYLOAD (tag 9) with the pixels after READY, and
/// KITTY_IMAGE_PAGE_PLACEMENTS (tag 10) for history pages. Before #38776 the
/// app also asked for the images phase and decoded every image a second time.
/// This attaches the way the app does (GHOSTSNP, local history, the app's
/// attach client) to a terminal that shows two images and counts what the
/// client gets: each image's pixels once, each placement once.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchSnapshotKittyImagesTests {
    /// A 64x64 RGB PNG (the cmux-tui fixture's). Ghostty decodes a PNG to RGBA: 16384 bytes of pixels.
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAEAAAABACAIAAAAlC+aJAAAAT0lEQVR42u3PQQkAAAgEsItjJhMbywi+hcEKLFP9WgQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQEBAQELgs6CKEtxmKJKgAAAABJRU5ErkJggg=="
    /// The GHOSTSNP version the app's linked libghostty reads
    /// (`ghostty_surface_snapshot_version`); this target links no Ghostty.
    private static let snapshotVersion: UInt16 = 1

    @Test func anAttachGetsEachKittyImageOnce() async throws {
        try await BranchDaemonHarness.with { h in
            let (_, _, surface) = try await h.workspaceWithTerminal("kitty-images")
            let place = { (id: Int) in #"printf '\033_Gf=100,a=T,i=\#(id),c=8,r=4;%s\033\\' \#(Self.png)"# }
            _ = try await h.run("stty -echo; \(place(11)); printf ' '; \(place(12)); printf '\\nimages-%s\\n' done",
                                in: surface, until: "images-done\r\n")

            let attachment = try await TerminalAttachment.attach(
                endpoint: h.endpoint, target: .init(surface: surface, generation: h.identity.generation),
                size: CellSize(cols: 120, rows: 30), claimGeometry: false,
                snapshotVersion: Self.snapshotVersion, localHistory: true)
            let watchdog = Task {
                try await Task.sleep(for: .seconds(15))
                await attachment.detach()
            }
            defer { watchdog.cancel() }
            var phases: [TerminalSnapshotFrame.Phase] = []
            var stream = Data()
            var records = GhostsnpRecords()
            for await event in attachment.events {
                guard case .snapshot(let frame) = event else { continue }
                phases.append(frame.phase)
                stream.append(frame.data)
                records = GhostsnpRecords(stream)
                if records.finished { break }
            }
            attachment.detachNow()

            let counts = records.kittyCounts
            print("KITTY-ATTACH phases=\(phases.map(\.rawValue)) snapshot_bytes=\(stream.count) " +
                  "storage_records=\(counts.storageRecords) images=\(counts.images) placements=\(counts.placements) " +
                  "page_placements=\(counts.pagePlacements) payloads=\(counts.payloads.map { "\($0.id):\($0.bytes)" })")
            #expect(records.finished, "the snapshot did not reach FINISH: phases \(phases), \(stream.count) bytes")
            #expect(phases.first == .ready && phases.dropFirst().allSatisfy { $0 == .history }, "\(phases)")
            #expect(counts.images == 2, "images in KITTY_IMAGE_STORAGE: \(counts.images)")
            #expect(counts.placements + counts.pagePlacements == 2, "placements: \(counts)")
            // Each image's pixels once: 64 x 64 x 4 bytes (RGBA).
            #expect(counts.payloads.map(\.id).sorted() == [11, 12], "pixel records: \(counts.payloads)")
            #expect(counts.payloads.allSatisfy { $0.bytes == 64 * 64 * 4 }, "pixel bytes: \(counts.payloads)")
        }
    }
}

/// The records of a GHOSTSNP stream (envelope "GHOSTSNP" + u16 version; then
/// u16 tag, u32 payload length, u32 CRC32C, payload; little-endian), read up
/// to the last complete record.
private struct GhostsnpRecords {
    struct Record { var tag: UInt16; var payload: Data }
    struct KittyCounts: CustomStringConvertible {
        var storageRecords = 0, images = 0, placements = 0, pagePlacements = 0
        var payloads: [(id: UInt32, bytes: UInt64)] = []
        var description: String {
            "storage \(storageRecords), images \(images), placements \(placements), page placements \(pagePlacements)"
        }
    }

    var records: [Record] = []

    init() {}

    init(_ data: Data) {
        let bytes = [UInt8](data)
        guard bytes.count >= 10, bytes[0..<8].elementsEqual("GHOSTSNP".utf8) else { return }
        var at = 10
        while at + 10 <= bytes.count {
            let tag = Self.int(bytes, at, 2)
            let length = Int(Self.int(bytes, at + 2, 4))
            guard at + 10 + length <= bytes.count else { break }
            records.append(Record(tag: UInt16(tag), payload: Data(bytes[(at + 10)..<(at + 10 + length)])))
            at += 10 + length
        }
    }

    var finished: Bool { records.contains { $0.tag == 6 } }

    var kittyCounts: KittyCounts {
        var counts = KittyCounts()
        for record in records {
            let p = [UInt8](record.payload)
            switch record.tag {
            case 8 where p.count >= 18:  // screen u16, next id u32, next placement u32, images u32, placements u32
                counts.storageRecords += 1
                counts.images += Int(Self.int(p, 10, 4))
                counts.placements += Int(Self.int(p, 14, 4))
            case 9 where p.count >= 18:  // screen u16, image id u32, frame u32, byte length u64, pixels
                counts.payloads.append((UInt32(Self.int(p, 2, 4)), Self.int(p, 10, 8)))
            case 10 where p.count >= 6:  // screen u16, placements u32
                counts.pagePlacements += Int(Self.int(p, 2, 4))
            default:
                break
            }
        }
        return counts
    }

    private static func int(_ bytes: [UInt8], _ at: Int, _ width: Int) -> UInt64 {
        (0..<width).reduce(UInt64(0)) { $0 | UInt64(bytes[at + $1]) << (8 * UInt64($1)) }
    }
}
