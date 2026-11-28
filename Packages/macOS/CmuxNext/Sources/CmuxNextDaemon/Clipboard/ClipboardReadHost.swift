import Foundation

/// Where a terminal that asks for the clipboard runs.
public enum ClipboardReadHostKind: String, Sendable, Hashable {
    case local, remote, cloud, unknown
}

/// The host a clipboard read names: its kind and, off this Mac, its name.
public struct ClipboardReadHost: Decodable, Sendable, Hashable {
    public var kind: ClipboardReadHostKind
    public var name: String?

    public init(kind: ClipboardReadHostKind, name: String? = nil) {
        self.kind = kind
        self.name = name
    }

    enum CodingKeys: String, CodingKey { case kind, name }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Fail closed without claiming an unknown origin is remote.
        kind = (try c.decodeIfPresent(String.self, forKey: .kind)).flatMap(ClipboardReadHostKind.init(rawValue:)) ?? .unknown
        name = try c.decodeIfPresent(String.self, forKey: .name)
    }
}
