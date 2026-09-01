public import Foundation

/// Builds bounded, ordered tmux `send-keys -H` command batches for literal input.
///
/// The builder owns the raw-input admission limit and encoded writer budget so
/// app adapters, input forwarders, and package tests cannot drift independently.
public enum RemoteTmuxSendKeysBatchBuilder {
    /// Largest logical manual-input event accepted by the remote tmux path.
    public static let maximumInputBytes = 256 * 1024

    /// Pending writer capacity required for one fully encoded maximum-size batch.
    public static let writerPendingByteLimit = maximumInputBytes * 4

    private static let maximumBytesPerCommand = 8 * 1024
    private static let lowercaseHexDigits = Array("0123456789abcdef".utf8)

    /// Encodes one logical input event as an ordered atomic command batch.
    ///
    /// - Parameters:
    ///   - paneID: Target tmux pane identifier without the leading `%`.
    ///   - data: Literal bytes to deliver in order.
    /// - Returns: Empty commands for empty input, `nil` above the admission
    ///   limit, or commands whose encoded lines remain below tmux's control-mode
    ///   command ceiling.
    public static func commands(paneID: Int, data: Data) -> [String]? {
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

    private static func hexByteArguments(_ data: Data.SubSequence) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(data.count * 3 - 1)
        for byte in data {
            if !bytes.isEmpty { bytes.append(UInt8(ascii: " ")) }
            bytes.append(lowercaseHexDigits[Int(byte >> 4)])
            bytes.append(lowercaseHexDigits[Int(byte & 0x0f)])
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}
