import Foundation
import os
import CmuxNextCompat
import CmuxNextWakeups

/// Attach-connection lines to channel events (byte replay and snapshot
/// attach). Attach frames go through ``TerminalAttachFrameDecoder``.
extension TerminalAttachment {
    private static let decodeLogger = Logger(subsystem: "com.cmuxterm.app.next", category: "daemon.attach")
    /// Attach lines and frames of a known event kind that failed to decode
    /// (a wire contract drift); diagnostics and tests.
    static let undecodableLines = Atomic<Int>(0)

    private struct Output: Decodable {
        var surface: SurfaceID?
        var data: Data
        var colors: TerminalColors?
        /// Present on a snapshot attach.
        var generation: UInt64?
        /// The key press this output echoes (`send` carried it and the PTY read stamped it); absent
        /// from a daemon without exact flows or when no press was open.
        var flow: UInt64?
        /// That press's daemon stages; absent from a daemon before them, or one whose clock is
        /// not this Mac's.
        var keyStages: KeyStages?
        /// The daemon's PTY offset after this chunk (a snapshot attach); counted only (``TerminalStreamLedger``).
        var offset: UInt64?

        enum CodingKeys: String, CodingKey {
            case surface, data, colors, generation, flow, offset
            case keyStages = "key_stages"
        }
    }

    /// `key_stages {received, written, read, sent, lost}` of an `output` that echoes a key press.
    private struct KeyStages: Decodable {
        var received: UInt64
        var written: UInt64
        var read: UInt64
        var sent: UInt64
        var lost: UInt64?

        var stamps: TerminalKeyStamps {
            TerminalKeyStamps(received: received, written: written, read: read, sent: sent, lost: lost ?? 0)
        }
    }

    private struct SizeStateEvent: Decodable {
        var surface: SurfaceID?
        var state: TerminalSizeState
        /// This connection's participant, when it is in the state.
        var selfParticipant: String?
        enum CodingKeys: String, CodingKey {
            case surface, state
            case selfParticipant = "self_participant"
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

    /// A known event whose line lacks a field it needs.
    private struct MissingField: Error {
        var name: String
    }

    /// Attach lines whose decode is bulk: a snapshot (its history chunks inflate) and a byte replay. They always
    /// decode on the connection's decode lane, never on its reader.
    static let bulkEvents: Set<String> = ["snapshot", "vt-state", "resized"]

    /// The reader's weighing of one attach line (``EventDispatch/weigh``), from its name and size only: bulk
    /// events and lines over ``DecodeLane/lightLineLimit`` are heavy; output and the small events run inline on
    /// the reader while its lane is idle, so an echo costs no thread hop.
    static func eventWeight(name: String, line: Data) -> DecodeLane.Weight {
        bulkEvents.contains(name) || line.count > DecodeLane.lightLineLimit ? .heavy : .light
    }

    /// The surface named by the first line of an attach (`vt-state`, or the
    /// READY `snapshot` of a snapshot attach); names an `unplaced` target.
    static func initialSurface(name: String, line: Data, decoder: WireDecoder) -> SurfaceID? {
        switch name {
        case "vt-state": return try? decoder.decode(TerminalVTStateWire.self, from: line).surface
        case "snapshot": return try? decoder.decode(SurfaceScoped.self, from: line).surface
        default: return nil
        }
    }

    /// Maps one attach-connection line to a channel event, plus the generation an `output` carries,
    /// for ``TerminalSnapshotSequencer``. Returns nil for events that belong to another surface or that
    /// views ignore. `decoder` is the connection's: it counts each decode, and its recorder each
    /// `output` payload decoded out of its line.
    static func decodeAttachLine(name: String, line: Data, surface: SurfaceID, decoder: WireDecoder) -> DecodedAttachLine? {
        func scoped(_ id: SurfaceID?) -> Bool { id == nil || id == surface }
        do {
            switch name {
            case "vt-state":
                let state = try decoder.decode(TerminalVTStateWire.self, from: line)
                guard scoped(state.surface) else { return nil }
                return DecodedAttachLine(event: .replay(state.terminalReplay))
            case "snapshot":
                let snapshot = try decoder.decode(TerminalSnapshotWire.self, from: line)
                guard let encoded = snapshot.data else { throw MissingField(name: "data") }
                guard scoped(snapshot.surface), let frame = snapshot.frame(data: encoded) else { return nil }
                return DecodedAttachLine(event: .snapshot(frame))
            case "output":
                let output = try decoder.decode(Output.self, from: line)
                decoder.recorder?.outputCopied(output.data.count)  // decoded out of the line, even if dropped below
                guard scoped(output.surface) else { return nil }
                return DecodedAttachLine(event: .output(output.data, colors: output.colors), generation: output.generation,
                                         flow: output.flow, keyStamps: output.keyStages?.stamps, offset: output.offset)
            case "resized":
                let state = try decoder.decode(TerminalVTStateWire.self, from: line)
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
            case "size-state":
                let event = try decoder.decode(SizeStateEvent.self, from: line)
                guard scoped(event.surface) else { return nil }
                return DecodedAttachLine(event: .sizeState(event.state, participant: event.selfParticipant))
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
            noteUndecodable(name)
            return nil
        }
    }

    /// Never silent: a known event the view cannot decode is a contract
    /// drift with the host. Kind and count only, no payload.
    static func noteUndecodable(_ name: String) {
        let count = undecodableLines.add(1, ordering: .relaxed).newValue
        decodeLogger.error("attach \(name, privacy: .public) failed to decode (\(count) so far)")
    }
}
