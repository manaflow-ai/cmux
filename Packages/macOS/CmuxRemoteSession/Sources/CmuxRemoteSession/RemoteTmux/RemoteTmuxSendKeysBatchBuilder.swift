public import Foundation

/// Builds bounded, ordered tmux `send-keys -H` command batches for literal input.
///
/// One configured builder owns the framing policy: the raw-input admission limit,
/// the per-command byte ceiling, and the encoded writer budget derived from the
/// admission limit. Callers inject the same instance into the control connection
/// and the pane input forwarder so app adapters, input forwarders, and package
/// tests cannot drift independently.
public struct RemoteTmuxSendKeysBatchBuilder: Sendable {
    /// Admission limit used when the caller does not configure its own.
    public static let defaultMaximumInputBytes = 256 * 1024

    /// Per-command literal byte ceiling used when the caller does not configure its own.
    public static let defaultMaximumBytesPerCommand = 8 * 1024

    /// Largest logical manual-input event this builder admits.
    public let maximumInputBytes: Int

    /// Largest literal byte run this builder frames into one `send-keys -H` command.
    public let maximumBytesPerCommand: Int

    /// Creates a framing policy; non-positive limits are clamped to one byte.
    ///
    /// - Parameters:
    ///   - maximumInputBytes: Largest admitted logical input event.
    ///   - maximumBytesPerCommand: Largest literal byte run per command.
    public init(
        maximumInputBytes: Int = RemoteTmuxSendKeysBatchBuilder.defaultMaximumInputBytes,
        maximumBytesPerCommand: Int = RemoteTmuxSendKeysBatchBuilder.defaultMaximumBytesPerCommand
    ) {
        self.maximumInputBytes = max(1, maximumInputBytes)
        self.maximumBytesPerCommand = max(1, maximumBytesPerCommand)
    }

    /// Pending writer capacity required for one fully encoded maximum-size batch.
    public var writerPendingByteLimit: Int { maximumInputBytes * 4 }

    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

    /// Encodes one logical input event as an ordered atomic command batch.
    ///
    /// - Parameters:
    ///   - paneID: Target tmux pane identifier without the leading `%`.
    ///   - data: Literal bytes to deliver in order.
    /// - Returns: Empty commands for empty input, `nil` above the admission
    ///   limit, or commands whose encoded lines remain below tmux's control-mode
    ///   command ceiling.
    public func commands(paneID: Int, data: Data) -> [String]? {
        guard data.count <= maximumInputBytes else { return nil }
        guard !data.isEmpty else { return [] }

        var commands: [String] = []
        commands.reserveCapacity(
            (data.count + maximumBytesPerCommand - 1) / maximumBytesPerCommand
        )

        var chunkStart = data.startIndex
        while chunkStart < data.endIndex {
            let chunkEnd = data.index(
                chunkStart,
                offsetBy: maximumBytesPerCommand,
                limitedBy: data.endIndex
            ) ?? data.endIndex
            let hex = hexByteArguments(data[chunkStart ..< chunkEnd])
            commands.append("send-keys -t %\(paneID) -H \(hex)")
            chunkStart = chunkEnd
        }
        return commands
    }

    private func hexByteArguments(_ data: Data.SubSequence) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 3 - 1)
        for byte in data {
            if !bytes.isEmpty { bytes.append(UInt8(ascii: " ")) }
            bytes.append(Self.lowercaseHexDigits[Int(byte >> 4)])
            bytes.append(Self.lowercaseHexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
