// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The live preview's video channel (`computer-use-preview` on cmux Remote's app socket, spliced
/// by the host to the Computer Use worker's preview socket). After the host's answer the app sends
/// one JSON line, `{"session": S, "long_side": N}`, then the worker sends messages until either side
/// closes: one kind byte, a big-endian UInt32 length, the payload.
///
/// - `S` status, JSON: `{"state": "streaming" | "still" | "no_window" | "blocked" | "paused", "width"?, "height"?, "app"?}`.
///   `blocked`: the window's app is kept private; the app shows no picture (and drops the one it had).
/// - `P` H.264 parameter sets: UInt16 length + SPS, UInt16 length + PPS.
/// - `F` one H.264 access unit: a flags byte (1: keyframe), a UInt64 presentation time in
///   microseconds, then the AVCC NAL units (4-byte big-endian lengths), as VideoToolbox writes them.
/// - `J` one JPEG still (the fallback when no stream starts).
///
/// Video never goes through the daemon's JSON lines: this is a local socket between two processes
/// of the same user, the host having checked the app's grant secret and process.
enum PreviewStreamWire {
    static let status: UInt8 = 0x53
    static let parameterSets: UInt8 = 0x50
    static let frame: UInt8 = 0x46
    static let still: UInt8 = 0x4A
    /// The one line the app sends after its request: `K`, when it dropped frames and needs a
    /// keyframe to decode again. Any other line is ignored.
    static let keyframeRequest = Data("K".utf8)
    /// The largest message either side accepts.
    static let maximumPayload = 8 * 1024 * 1024

    /// One message.
    static func message(_ kind: UInt8, _ payload: Data) -> Data {
        var data = Data(capacity: payload.count + 5)
        data.append(kind)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(payload)
        return data
    }

    static func status(_ fields: [String: Any]) -> Data {
        message(status, (try? JSONSerialization.data(withJSONObject: fields)) ?? Data("{}".utf8))
    }

    static func parameterSets(sps: Data, pps: Data) -> Data {
        var payload = Data()
        for set in [sps, pps] {
            withUnsafeBytes(of: UInt16(set.count).bigEndian) { payload.append(contentsOf: $0) }
            payload.append(set)
        }
        return message(parameterSets, payload)
    }

    static func frame(keyframe: Bool, microseconds: UInt64, avcc: Data) -> Data {
        var payload = Data(capacity: avcc.count + 9)
        payload.append(keyframe ? 1 : 0)
        withUnsafeBytes(of: microseconds.bigEndian) { payload.append(contentsOf: $0) }
        payload.append(avcc)
        return message(frame, payload)
    }

    /// The app's request line: the session and the preview's longest side in pixels (clamped to
    /// ``minimumLongSide``...``maximumLongSide``).
    struct Request: Equatable, Sendable {
        static let minimumLongSide = 64
        static let maximumLongSide = 1600
        static let defaultLongSide = 960

        var session: String
        var longSide: Int

        init?(_ object: [String: Any]?) {
            guard let object, let session = SessionControl.sessionKey(object["session"]) else { return nil }
            self.session = session
            let side = (object["long_side"] as? NSNumber)?.intValue ?? Self.defaultLongSide
            longSide = min(max(side, Self.minimumLongSide), Self.maximumLongSide)
        }
    }
}
