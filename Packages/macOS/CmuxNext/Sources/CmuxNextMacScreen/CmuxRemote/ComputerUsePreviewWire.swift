// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation

/// The lines the app sends on a preview channel after its request line.
nonisolated struct PreviewChannelLine: Sendable {
    /// `K`: frames were dropped; the next frame should be a keyframe (cmux Remote's
    /// `PreviewStreamWire.keyframeRequest`; an older one ignores it).
    static let keyframeRequest = Data("K\n".utf8)
}

/// What the worker says of a stream (`S` messages).
public nonisolated struct ComputerUsePreviewStatus: Equatable, Sendable {
    public enum State: String, Sendable {
        /// Live video.
        case streaming
        /// No stream started: stills stand in.
        case still
        /// The session has no window now (it closed, or the agent has not used one yet).
        case noWindow = "no_window"
        /// The window's app is kept private: no picture at all.
        case blocked
        /// The stream stopped (the window moved off screen, or capture failed).
        case paused
    }

    public var state: State
    public var width: Int?
    public var height: Int?
    public var appName: String?
    /// The window generation a `streaming` status names (cmux Remote counts the windows it streamed
    /// for the session); nil from an older cmux Remote.
    public var window: Int?

    public init(state: State, width: Int? = nil, height: Int? = nil, appName: String? = nil, window: Int? = nil) {
        self.state = state
        self.width = width
        self.height = height
        self.appName = appName
        self.window = window
    }

    /// The status of an `S` message; nil for a state this build does not know (a newer worker's).
    public init?(_ object: [String: Any]) {
        guard let raw = object["state"] as? String, let state = State(rawValue: raw) else { return nil }
        let app = (object["app"] as? [String: Any])?["name"] as? String
        self.init(state: state, width: (object["width"] as? NSNumber)?.intValue, height: (object["height"] as? NSNumber)?.intValue,
                  appName: app?.isEmpty == false ? app : nil, window: (object["window"] as? NSNumber)?.intValue)
    }
}

/// The preview channel's messages as the app reads them (cmux Remote's `PreviewStreamWire`): a kind
/// byte, a big-endian UInt32 length, the payload. An unknown kind is skipped.
public nonisolated struct ComputerUsePreviewWire: Sendable {
    public static let status: UInt8 = 0x53
    public static let parameterSets: UInt8 = 0x50
    public static let frame: UInt8 = 0x46
    public static let still: UInt8 = 0x4A
    public static let maximumPayload = 8 * 1024 * 1024

    public init() {}

    /// The SPS and PPS of a `P` payload.
    public static func parameterSets(_ payload: Data) -> (sps: Data, pps: Data)? {
        let bytes = [UInt8](payload)
        var offset = 0
        func next() -> Data? {
            guard offset + 2 <= bytes.count else { return nil }
            let length = Int(UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1]))
            offset += 2
            guard length > 0, offset + length <= bytes.count else { return nil }
            defer { offset += length }
            return Data(bytes[offset..<offset + length])
        }
        guard let sps = next(), let pps = next() else { return nil }
        return (sps, pps)
    }

    /// The keyframe flag, time and access unit of an `F` payload.
    public static func frame(_ payload: Data) -> (keyframe: Bool, microseconds: UInt64, avcc: Data)? {
        let bytes = [UInt8](payload)
        guard bytes.count > 9 else { return nil }
        var micros: UInt64 = 0
        for byte in bytes[1..<9] { micros = micros << 8 | UInt64(byte) }
        return (bytes[0] & 1 == 1, micros, Data(bytes[9...]))
    }
}
