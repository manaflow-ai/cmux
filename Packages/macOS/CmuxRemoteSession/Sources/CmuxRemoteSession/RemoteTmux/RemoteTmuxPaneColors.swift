import Foundation

/// Terminal defaults reported by a control-mode client, not pane style overrides.
public struct RemoteTmuxPaneColors: Equatable, Sendable {
    public let foreground: String
    public let background: String

    public init?(foreground: String, background: String) {
        guard let foreground = Self.normalizedHex(foreground),
              let background = Self.normalizedHex(background) else { return nil }
        self.foreground = foreground
        self.background = background
    }

    public func reportCommands(paneId: Int) -> [String] {
        let foreground = Self.oscRGB(foreground)
        let background = Self.oscRGB(background)
        // tmux consumes only the last -r on a command, so each endpoint needs
        // its own command. Octal escapes are expanded inside double quotes.
        return [
            "refresh-client -r \"%\(paneId):\\033]10;rgb:\(foreground)\\007\"",
            "refresh-client -r \"%\(paneId):\\033]11;rgb:\(background)\\007\"",
        ]
    }

    private static func normalizedHex(_ value: String) -> String? {
        guard value.utf8.count == 7, value.hasPrefix("#"),
              value.dropFirst().allSatisfy(\.isHexDigit),
              let rgb = UInt32(value.dropFirst(), radix: 16) else { return nil }
        return String(format: "#%06x", rgb)
    }

    private static func oscRGB(_ value: String) -> String {
        let hex = Array(value.dropFirst())
        return stride(from: 0, to: hex.count, by: 2).map { index in
            let channel = String(hex[index...index + 1])
            return channel + channel
        }.joined(separator: "/")
    }
}
