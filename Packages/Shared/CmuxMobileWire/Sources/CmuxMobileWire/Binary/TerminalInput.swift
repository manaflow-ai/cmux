public import Foundation

/// Terminal channel, viewer to host: `u8 kind` + payload.
public struct TerminalInput: Hashable, Sendable {
    public var kind: TerminalInputKind
    public var data: Data

    public init(kind: TerminalInputKind, data: Data) {
        self.kind = kind
        self.data = data
    }

    public init(decoding payload: Data) throws(RecordError) {
        guard let first = payload.first, let kind = TerminalInputKind(rawValue: first) else {
            throw RecordError(.truncated, "unknown terminal input kind")
        }
        self.init(kind: kind, data: payload.tail(from: 1))
    }

    public var encoded: Data {
        var out = Data([kind.rawValue])
        out.append(data)
        return out
    }
}
