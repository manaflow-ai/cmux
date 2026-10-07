import Foundation

/// Any JSON value, kept as parsed (red-commit placeholder).
public nonisolated indirect enum RemoteRdJSON: Sendable, Equatable {
    case null
}

nonisolated extension RemoteRdJSON: Codable {
    public init(from decoder: any Decoder) throws {
        self = .null
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encodeNil()
    }
}
