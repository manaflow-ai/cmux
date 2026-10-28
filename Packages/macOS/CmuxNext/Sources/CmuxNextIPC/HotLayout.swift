// The binary codec of the hot messages (p05-ipc-183; cmux-tui/spec/transports.md, "Binary payload
// layouts").
//
// The requests and results of `resize-attached-view`, `set-client-sizing`, `scroll-surface` and
// `snapshot-request`, and the `size-state`, `scroll-changed`, `surface-resized` and `digest` events,
// run on every resize, scroll and snapshot. Their frames carry a fixed little-endian layout instead of JSON,
// so neither end parses JSON for them. CmuxNextWireGen's HotEmitter writes `HotCodec+Schema.swift`
// (one `Hot…` type per body and per type it reaches, and one ``HotLayout`` per body) into the plugin
// work directory from cmux-tui/spec/sdk-schema.json; nothing generated is committed. The Rust twin is
// cmux-tui/crates/cmux-ipc/src/hot.rs, and both are checked against
// cmux-tui/spec/fixtures/ipc-hot-codec/golden.json.
//
// A payload starts with its layout version; ``HotLayout/decode(_:)`` refuses any other, so a peer
// built from another schema revision is refused rather than misread (Mojo's validated struct header,
// mojo/public/cpp/bindings/lib/validation_util.h). ``HotLayout/encode(_:)`` refuses a value over its
// layout's bounds; the sender then writes the same message as a JSON frame. A frame's `binary` call
// flag says which decoder reads its payload.

import Foundation

/// Which body of a message a layout carries.
public enum HotPart: String, Hashable, Sendable {
    /// A command's request (a REQUEST frame).
    case request
    /// A command's result (a REPLY frame).
    case result
    /// An event's payload (a TYPED_EVENT frame), without its `event` member.
    case event
}

/// What a binary layout is, without its body type.
public struct HotLayoutInfo: Hashable, Sendable {
    /// The command or event name.
    public let name: String
    public let part: HotPart
    /// The `method_id` or `event_id`.
    public let wireID: UInt16
    /// The first payload byte.
    public let layoutVersion: UInt8
    /// The generated body type, without the `Hot` prefix (the Rust name).
    public let typeName: String

    public init(name: String, part: HotPart, wireID: UInt16, layoutVersion: UInt8, typeName: String) {
        self.name = name
        self.part = part
        self.wireID = wireID
        self.layoutVersion = layoutVersion
        self.typeName = typeName
    }
}

/// One binary layout and the type of its body. HotEmitter declares one per message as a static
/// member of its body type's specialization (`HotLayout<HotScrollSurfaceRequest>.scrollSurfaceRequest`).
public struct HotLayout<Body: HotValue>: Hashable, Sendable {
    public let info: HotLayoutInfo

    public init(_ info: HotLayoutInfo) {
        self.info = info
    }

    /// The version byte, then `value`.
    public func encode(_ value: Body) throws(HotEncodeError) -> [UInt8] {
        var writer = HotWriter(layoutVersion: info.layoutVersion)
        try value.hotWrite(to: &writer)
        return writer.bytes
    }

    /// The body of `payload`: the version byte must be this layout's, and every byte after it must
    /// belong to the body.
    public func decode(_ payload: [UInt8]) throws(HotDecodeError) -> Body {
        guard let version = payload.first else { throw .truncated }
        guard version == info.layoutVersion else {
            throw .version(name: info.name, expected: info.layoutVersion, found: version)
        }
        var reader = HotReader(bytes: payload, start: 1)
        let body = try Body(hotReader: &reader)
        guard reader.remaining == 0 else { throw .trailingBytes(reader.remaining) }
        return body
    }

    /// ``decode(_:)`` of a frame payload.
    public func decode(_ payload: Data) throws(HotDecodeError) -> Body {
        try decode([UInt8](payload))
    }
}
