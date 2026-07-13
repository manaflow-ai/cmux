import Foundation

struct BrowserAuthPromptTextFormatter {
    private static let defaultDangerousScalars: Set<Unicode.Scalar> = [
        "\u{200B}", "\u{200C}", "\u{200D}", "\u{200E}", "\u{200F}",
        "\u{202A}", "\u{202B}", "\u{202C}", "\u{202D}", "\u{202E}",
        "\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}",
        "\u{FEFF}",
    ]

    private let textMaxLength: Int
    private let dangerousScalars: Set<Unicode.Scalar>

    init(
        textMaxLength: Int = 240,
        dangerousScalars: Set<Unicode.Scalar> = Self.defaultDangerousScalars
    ) {
        self.textMaxLength = textMaxLength
        self.dangerousScalars = dangerousScalars
    }

    func filteredText(_ text: String) -> String {
        let filtered = String(text.unicodeScalars.filter { scalar in
            !dangerousScalars.contains(scalar)
                && !CharacterSet.controlCharacters.contains(scalar)
        })
        return filtered.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func sanitizedText(_ text: String) -> String {
        let trimmed = filteredText(text)
        guard trimmed.count > textMaxLength else {
            return trimmed
        }
        return String(trimmed.prefix(textMaxLength))
    }

    func middleElidedText(_ text: String) -> String {
        let trimmed = filteredText(text)
        guard trimmed.count > textMaxLength else {
            return trimmed
        }

        let marker = "..."
        let keptCharacterCount = textMaxLength - marker.count
        let prefixCount = min(48, max(16, keptCharacterCount / 3))
        let suffixCount = max(0, keptCharacterCount - prefixCount)
        return String(trimmed.prefix(prefixCount)) + marker + String(trimmed.suffix(suffixCount))
    }

    func defaultPort(forProtocol protocolName: String?) -> Int? {
        switch protocolName?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return nil
        }
    }

    func origin(
        protectionSpace: URLProtectionSpace,
        unknownHost: String
    ) -> String {
        let host = filteredText(protectionSpace.host)
        guard !host.isEmpty else {
            return unknownHost
        }

        let rawProtocol = protectionSpace.`protocol` ?? ""
        let protocolName = filteredText(rawProtocol).lowercased()
        let defaultPort = defaultPort(forProtocol: protocolName)

        let displayHost: String
        if host.contains(":") && !host.hasPrefix("[") && !host.hasSuffix("]") {
            displayHost = "[\(host)]"
        } else {
            displayHost = host
        }

        let port = protectionSpace.port
        let authority: String
        if port > 0, port != defaultPort {
            authority = "\(displayHost):\(port)"
        } else {
            authority = displayHost
        }

        let origin = protocolName.isEmpty ? authority : "\(protocolName)://\(authority)"
        return middleElidedText(origin)
    }
}
