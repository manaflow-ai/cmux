import Foundation
import os
import CmuxNextCompat

/// Attach-connection lines to channel events (byte replay and snapshot
/// attach).
extension TerminalAttachment {
    private static let decodeLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.attach")
    /// Attach lines of a known event kind that failed to decode (a wire
    /// contract drift); diagnostics and tests.
    static let undecodableLines = Atomic<Int>(0)

    private struct VTState: Decodable {
        var surface: SurfaceID?
        var cols: Int
        var rows: Int
        var data: Data?
        var replay: Data?
        var colors: TerminalColors?
        var kittyImageAliases: [KittyImageAlias]?
        var kittyGraphicsState: KittyGraphicsState?
        var pending: Data?

        enum CodingKeys: String, CodingKey {
            case surface, cols, rows, data, replay, colors, pending
            case kittyImageAliases = "kitty_image_aliases"
            case kittyGraphicsState = "kitty_graphics_state"
        }

        var terminalReplay: TerminalReplay {
            TerminalReplay(cols: cols, rows: rows, data: replay ?? data ?? Data(), colors: colors,
                           kittyImageAliases: kittyImageAliases ?? [], kittyGraphicsState: kittyGraphicsState,
                           pending: pending ?? Data())
        }
    }

    private struct Output: Decodable {
        var surface: SurfaceID?
        var data: Data
        var colors: TerminalColors?
        /// Present on a snapshot attach.
        var generation: UInt64?
    }

    /// `snapshot {phase, generation, offset, version, cols?, rows?, colors?, data}`.
    /// `marker_epoch` and `active_top_marker` (row markers for
    /// `terminal-history`) are not used by the view.
    private struct Snapshot: Decodable {
        var surface: SurfaceID?
        var phase: String
        var generation: UInt64
        var offset: UInt64
        var version: UInt16
        var cols: Int?
        var rows: Int?
        var colors: TerminalColors?
        /// Absent from the JSON of a binary event frame, which carries the
        /// bytes beside it.
        var data: Data?
        /// History chunks: `deflate` (raw DEFLATE) and the inflated length.
        var compression: String?
        var rawBytes: Int?
        /// A local-history READY: `history: "local"` with the host's check.
        var history: String?
        var historyRows: UInt64?
        var historyDigest: String?
        var skippedImages: Int?

        enum CodingKeys: String, CodingKey {
            case surface, phase, generation, offset, version, cols, rows, colors, data, compression, history
            case rawBytes = "raw_bytes"
            case historyRows = "history_rows"
            case historyDigest = "history_digest"
            case skippedImages = "skipped_images"
        }

        /// The check of a local-history READY; nil (a plain READY whose
        /// history is lost) when it is missing or malformed.
        var localHistory: TerminalLocalHistoryCheck? {
            guard phase == "ready", history == "local", let historyRows,
                  let digest = historyDigest.flatMap(TerminalLocalHistoryCheck.digest(hex:)) else { return nil }
            return TerminalLocalHistoryCheck(rows: historyRows, digest: digest)
        }
    }

    private struct SurfaceScoped: Decodable {
        var surface: SurfaceID?
        var scope: String?
        var offset: UInt64?
        var atBottom: Bool?
        enum CodingKeys: String, CodingKey {
            case surface, scope, offset
            case atBottom = "at_bottom"
        }
    }

    /// A snapshot event with its data (from its JSON line or beside the JSON
    /// of a binary frame).
    private static func snapshotLine(_ snapshot: Snapshot, data packed: Data, surface: SurfaceID) -> DecodedAttachLine? {
        guard snapshot.surface == nil || snapshot.surface == surface,
              let phase = TerminalSnapshotFrame.Phase(rawValue: snapshot.phase),
              phase != .ready || (snapshot.cols != nil && snapshot.rows != nil)
        else { return nil }  // A READY without its grid cannot lock the mirror's grid.
        // An unknown codec or a bad chunk would corrupt the restore: refused.
        guard let data = TerminalSnapshotInflate.inflate(packed, compression: snapshot.compression,
                                                         rawBytes: snapshot.rawBytes)
        else {
            decodeLogger.error("""
                snapshot \(snapshot.phase, privacy: .public) chunk refused: compression \(snapshot.compression ?? "none", privacy: .public), \
                raw_bytes \(snapshot.rawBytes ?? -1), \(packed.count) bytes
                """)
            return nil
        }
        return DecodedAttachLine(event: .snapshot(TerminalSnapshotFrame(
            phase: phase, generation: snapshot.generation, offset: snapshot.offset, version: snapshot.version,
            cols: snapshot.cols, rows: snapshot.rows, colors: snapshot.colors,
            localHistory: snapshot.localHistory, skippedImages: snapshot.skippedImages, data: data)))
    }

    /// The JSON and the data of an event frame.
    private static func eventParts(_ frame: BinaryFrame) -> (json: Data, data: Data)? {
        guard frame.kind == BinaryFrame.eventData, frame.payload.count >= 4 else { return nil }
        let jsonLength = Int(frame.payload.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
        guard jsonLength <= frame.payload.count - 4 else { return nil }
        let start = frame.payload.startIndex + 4
        return (frame.payload[start..<(start + jsonLength)], frame.payload[(start + jsonLength)...])
    }

    /// The surface named by the first frame of an attach (the READY of a
    /// snapshot attach, or an output frame); names an `unplaced` target.
    static func initialSurface(frame: BinaryFrame) -> SurfaceID? {
        switch frame.kind {
        case BinaryFrame.output: return frame.word(at: 0).map(SurfaceID.init(rawValue:))
        case BinaryFrame.eventData:
            guard let (json, _) = eventParts(frame) else { return nil }
            return try? WireCoding.decoder().decode(SurfaceScoped.self, from: json).surface
        default: return nil
        }
    }

    /// Maps one binary frame (`terminal-binary-frames-v1`) to a channel
    /// event, as ``decodeAttachLine(name:line:surface:)`` maps the JSON
    /// event it stands for. Output needs no JSON decoder and no base64.
    static func decodeAttachFrame(_ frame: BinaryFrame, surface: SurfaceID) -> DecodedAttachLine? {
        switch frame.kind {
        case BinaryFrame.output:
            guard let id = frame.word(at: 0), let generation = frame.word(at: 8), frame.word(at: 16) != nil else { break }
            guard SurfaceID(rawValue: id) == surface else { return nil }
            let data = frame.payload.dropFirst(24)
            let positioned = frame.flags & BinaryFrame.outputPosition != 0
            return DecodedAttachLine(event: .output(Data(data), colors: nil), generation: positioned ? generation : nil)
        case BinaryFrame.eventData:
            guard let (json, data) = eventParts(frame) else { break }
            let decoder = WireCoding.decoder()
            guard let name = try? decoder.decode(EventName.self, from: json).event else { break }
            // Only snapshot data travels this way today; another event is
            // a contract drift, counted like an undecodable line.
            if name == "snapshot", let snapshot = try? decoder.decode(Snapshot.self, from: json) {
                return snapshotLine(snapshot, data: Data(data), surface: surface)
            }
        default:
            break
        }
        let count = undecodableLines.add(1, ordering: .relaxed).newValue
        decodeLogger.error("attach frame of kind \(frame.kind) failed to decode (\(count) so far)")
        return nil
    }

    private struct EventName: Decodable {
        var event: String?
    }

    /// The surface named by the first line of an attach (`vt-state`, or the
    /// READY `snapshot` of a snapshot attach); names an `unplaced` target.
    static func initialSurface(name: String, line: Data) -> SurfaceID? {
        let decoder = WireCoding.decoder()
        switch name {
        case "vt-state": return try? decoder.decode(VTState.self, from: line).surface
        case "snapshot": return try? decoder.decode(SurfaceScoped.self, from: line).surface
        default: return nil
        }
    }

    /// Maps one attach-connection line to a channel event. Returns nil for
    /// events that belong to another surface or that views ignore.
    static func decodeAttachEvent(name: String, line: Data, surface: SurfaceID) -> TerminalChannelEvent? {
        decodeAttachLine(name: name, line: line, surface: surface)?.event
    }

    /// ``decodeAttachEvent(name:line:surface:)`` plus the generation an
    /// `output` carries, for ``TerminalSnapshotSequencer``.
    static func decodeAttachLine(name: String, line: Data, surface: SurfaceID) -> DecodedAttachLine? {
        let decoder = WireCoding.decoder()
        func scoped(_ id: SurfaceID?) -> Bool { id == nil || id == surface }
        do {
            switch name {
            case "vt-state":
                let state = try decoder.decode(VTState.self, from: line)
                guard scoped(state.surface) else { return nil }
                return DecodedAttachLine(event: .replay(state.terminalReplay))
            case "snapshot":
                let snapshot = try decoder.decode(Snapshot.self, from: line)
                guard let data = snapshot.data else { throw DecodingError.valueNotFound(Data.self, .init(codingPath: [], debugDescription: "snapshot data")) }
                return snapshotLine(snapshot, data: data, surface: surface)
            case "output":
                let output = try decoder.decode(Output.self, from: line)
                guard scoped(output.surface) else { return nil }
                return DecodedAttachLine(event: .output(output.data, colors: output.colors), generation: output.generation)
            case "resized":
                let state = try decoder.decode(VTState.self, from: line)
                guard scoped(state.surface) else { return nil }
                return DecodedAttachLine(event: .resized(state.terminalReplay))
            case "colors-changed":
                let scope = try decoder.decode(SurfaceScoped.self, from: line)
                guard scoped(scope.surface) else { return nil }
                return DecodedAttachLine(event: .colorsChanged(try decoder.decode(TerminalColors.self, from: line)))
            case "scroll-changed":
                let scope = try decoder.decode(SurfaceScoped.self, from: line)
                guard scope.surface == surface, let offset = scope.offset else { return nil }
                return DecodedAttachLine(event: .scrollChanged(offset: offset, atBottom: scope.atBottom ?? true))
            case "detached":
                let scope = try decoder.decode(SurfaceScoped.self, from: line)
                guard scoped(scope.surface) else { return nil }
                return DecodedAttachLine(event: .closed(.surfaceGone))
            case "overflow":
                let scope = try decoder.decode(SurfaceScoped.self, from: line)
                guard scoped(scope.surface) else { return nil }
                return DecodedAttachLine(event: .closed(.overflow))
            // "digest" (idle drift check): comparing it needs the view to
            // encode its own READY (plans/cmux-next/ghostty-next.md section 2,
            // "Drift repair"); until the view does, drift is repaired only by
            // the next attach or grid snapshot. Not a view event.
            default:
                return nil
            }
        } catch {
            // Never silent: a known event the view cannot decode is a contract
            // drift with the host. Kind and count only, no payload.
            let count = undecodableLines.add(1, ordering: .relaxed).newValue
            decodeLogger.error("attach line \(name, privacy: .public) failed to decode (\(count) so far)")
            return nil
        }
    }
}
