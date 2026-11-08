public import Foundation

/// One ordered input event emitted by a manual-I/O terminal surface.
public enum TerminalManualInput: Sendable {
    /// Bytes encoded by Ghostty for literal text or an unsupported key.
    case bytes(Data)
    /// A physical key name that the owning transport must encode.
    case namedKey(String)

    // Invalid UTF-8 cannot be produced by Ghostty's key, mouse, paste, or
    // committed-text encoders, so this frame cannot collide with user input.
    private static let namedKeyFramePrefix = Data([
        0xFF, 0x00, 0x63, 0x6D, 0x75, 0x78, 0x2D, 0x6B, 0x65, 0x79, 0x00,
    ])

    /// Encodes this input for ordered delivery through Ghostty's I/O mailbox.
    var manualIOData: Data {
        switch self {
        case .bytes(let data):
            return data
        case .namedKey(let name):
            var data = Self.namedKeyFramePrefix
            data.append(contentsOf: name.utf8)
            return data
        }
    }

    /// Decodes an I/O callback as either a transport key or literal bytes.
    init(manualIOData data: Data) {
        guard data.starts(with: Self.namedKeyFramePrefix),
              data.count > Self.namedKeyFramePrefix.count,
              let name = String(
                  bytes: data.dropFirst(Self.namedKeyFramePrefix.count),
                  encoding: .utf8
              ) else {
            self = .bytes(data)
            return
        }
        self = .namedKey(name)
    }
}
