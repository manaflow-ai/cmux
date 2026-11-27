// SPDX-License-Identifier: GPL-3.0-or-later
public import Foundation

/// cmux Remote's wire (docs/cmux-remote.md, IPC): UTF-8 JSON, one object per
/// line, on every socket and pipe between the daemon, the host, its workers
/// and the app. A request is `{"id":N,"method":M,"params":{...}}`; its answer
/// `{"id":N,"ok":true,"result":{...}}` or `{"id":N,"ok":false,"error":{"code":C,"message":T}}`;
/// a push `{"type":"event","event":E,...}`.
public struct RemoteWire: Sendable {
    /// The supervisor protocol this build speaks. A daemon and a host pick the
    /// highest version both speak (`negotiate`); raise `maximum` only with a
    /// negotiated addition, so an adopted host of an older build keeps working.
    public static let minimumProtocol = 1
    public static let maximumProtocol = 1
    public static let maxLineBytes = 16 << 20

    public init() {}

    /// The version both sides speak, or nil when their ranges do not meet.
    public static func negotiate(peerMinimum: Int, peerMaximum: Int) -> Int? {
        let chosen = min(peerMaximum, maximumProtocol)
        return chosen >= max(peerMinimum, minimumProtocol) ? chosen : nil
    }

    public static func object(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    public static func line(_ fields: [String: Any]) -> Data {
        var body = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data("{}".utf8)
        body.append(0x0A)
        return body
    }

    public static func answer(id: Any?, result: [String: Any]) -> Data {
        line(["id": id ?? NSNull(), "ok": true, "result": result])
    }

    public static func failure(id: Any?, code: String, message: String) -> Data {
        line(["id": id ?? NSNull(), "ok": false, "error": ["code": code, "message": message]])
    }

    public static func event(_ name: String, _ fields: [String: Any] = [:]) -> Data {
        var all = fields
        all["type"] = "event"
        all["event"] = name
        return line(all)
    }

    public static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    public static func unhex(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// 32 random bytes.
    public static func makeSecret() -> Data {
        var generator = SystemRandomNumberGenerator()
        return Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }

    /// Compares two secrets in time that does not depend on where they differ.
    public static func sameSecret(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) { difference |= left ^ right }
        return difference == 0
    }
}

/// Splits a byte stream into lines.
public struct LineBuffer: Sendable {
    private var pending = Data()

    public init() {}

    /// Appends bytes; returns the complete lines (without "\n"), or nil when a line is too long.
    public mutating func append(_ bytes: Data) -> [Data]? {
        pending.append(bytes)
        var lines: [Data] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            lines.append(Data(pending[pending.startIndex..<newline]))
            pending.removeSubrange(pending.startIndex...newline)
        }
        return pending.count > RemoteWire.maxLineBytes ? nil : lines
    }

    /// Bytes after the last complete line (a channel's first raw bytes after its opening line).
    public mutating func takeRemainder() -> Data {
        defer { pending = Data() }
        return pending
    }
}

/// The two features cmux Remote hosts, each in its own worker process.
public enum RemoteWorkerKind: String, Sendable, CaseIterable, Codable {
    case computerUse = "computer-use"
    case screenSharing = "screen-sharing"
}

/// The two grants cmux Remote holds.
public enum RemotePermission: String, Sendable, CaseIterable, Codable {
    case accessibility
    case screenRecording = "screen-recording"

    /// The System Settings pane that lists it.
    public var settingsURL: URL? {
        let pane = self == .accessibility ? "Privacy_Accessibility" : "Privacy_ScreenCapture"
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
    }
}

/// The files of one host, in its 0700 directory (the daemon names it).
public struct RemoteHostLayout: Sendable, Equatable {
    public let directory: String

    public init(directory: String) { self.directory = directory }

    /// The daemon's supervisor socket: hello, requests, events.
    public var supervisorSocket: String { directory + "/s.sock" }
    /// The app's socket: device signing, hub push relay, Computer Use control.
    public var appSocket: String { directory + "/a.sock" }
    /// The Screen Sharing worker's own socket (the host forwards to it).
    public var screenSharingSocket: String { directory + "/w-screen.sock" }
    /// The adoption record the daemon writes (`docs/cmux-remote.md`, Lifecycle).
    public var record: String { directory + "/host.json" }
    public var log: String { directory + "/host.log" }
}
