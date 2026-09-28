/// One OSC 21337 update: `status=`, `detail=`, `indicator=`, `status-color=`.
///
/// A nil field means the key was absent and keeps its previous value; an
/// empty string clears it. Colors are normalized to lowercase `#rrggbb`.
/// Format: https://iterm2.com/documentation-session-status.html
public struct TerminalSessionStatusUpdate: Equatable, Sendable {
    public var status: String?
    public var detail: String?
    public var indicator: String?
    public var statusColor: String?

    public init(
        status: String? = nil,
        detail: String? = nil,
        indicator: String? = nil,
        statusColor: String? = nil
    ) {
        self.status = status
        self.detail = detail
        self.indicator = indicator
        self.statusColor = statusColor
    }

    /// Parses the payload after `21337;`. Returns nil when no known key has a
    /// usable value, so unknown keys and malformed colors change nothing.
    public static func parse(payload: some Sequence<UInt8>) -> TerminalSessionStatusUpdate? {
        var update = TerminalSessionStatusUpdate()
        var recognized = false
        let text = String(decoding: Array(payload), as: UTF8.self)
        for item in text.split(separator: ";", omittingEmptySubsequences: true) {
            guard let equals = item.firstIndex(of: "=") else { continue }
            let key = item[..<equals]
            let value = item[item.index(after: equals)...]
            switch key {
            case "status":
                update.status = sanitizedText(value, limit: TerminalSessionStatus.maximumStatusCharacters)
            case "detail":
                update.detail = sanitizedText(value, limit: TerminalSessionStatus.maximumDetailCharacters)
            case "indicator":
                guard let color = normalizedColor(value) else { continue }
                update.indicator = color
            case "status-color":
                guard let color = normalizedColor(value) else { continue }
                update.statusColor = color
            default:
                continue
            }
            recognized = true
        }
        return recognized ? update : nil
    }

    private static func sanitizedText(_ value: Substring, limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in value.unicodeScalars where scalar.properties.generalCategory != .control {
            scalars.append(scalar)
        }
        let trimmed = String(scalars).trimmingWhitespace()
        return String(trimmed.prefix(limit))
    }

    /// Empty clears the color; nil means the value is not a supported color.
    private static func normalizedColor(_ value: Substring) -> String? {
        let raw = value.trimmingWhitespace()
        if raw.isEmpty { return "" }
        let components: [Substring]
        if raw.hasPrefix("#") {
            let hex = raw.dropFirst()
            guard hex.count == 6 else { return nil }
            components = [hex.prefix(2), hex.dropFirst(2).prefix(2), hex.suffix(2)]
        } else if raw.lowercased().hasPrefix("rgb:") {
            components = raw.dropFirst(4).split(separator: "/", omittingEmptySubsequences: false)
        } else {
            return nil
        }
        guard components.count == 3 else { return nil }
        var result = "#"
        for component in components {
            // xterm allows 1 to 4 hex digits per channel; keep the high byte.
            guard (1...4).contains(component.count),
                  component.allSatisfy(\.isHexDigit),
                  let channel = UInt32(component, radix: 16) else {
                return nil
            }
            let maximum = (UInt32(1) << (4 * UInt32(component.count))) - 1
            let byte = (channel * 255 + maximum / 2) / maximum
            let digits = String(byte, radix: 16)
            result += digits.count == 1 ? "0" + digits : digits
        }
        return result
    }
}

/// The session status a surface has published, after applying updates in order.
public struct TerminalSessionStatus: Equatable, Sendable {
    public static let maximumStatusCharacters = 80
    public static let maximumDetailCharacters = 160

    public private(set) var status: String?
    public private(set) var detail: String?
    public private(set) var indicator: String?
    public private(set) var statusColor: String?

    public init() {}

    public mutating func apply(_ update: TerminalSessionStatusUpdate) {
        Self.merge(update.status, into: &status)
        Self.merge(update.detail, into: &detail)
        Self.merge(update.indicator, into: &indicator)
        Self.merge(update.statusColor, into: &statusColor)
    }

    /// A status or detail is showing; colors alone draw nothing.
    public var isVisible: Bool { displayText != nil }

    /// Status, then detail after a middle dot; nil when both are cleared.
    public var displayText: String? {
        switch (status, detail) {
        case let (status?, detail?): "\(status) · \(detail)"
        case let (status?, nil): status
        case let (nil, detail?): detail
        case (nil, nil): nil
        }
    }

    /// The sidebar entry has one color for its dot and text: the indicator
    /// when set, otherwise the status text color.
    public var displayColor: String? { indicator ?? statusColor }

    private static func merge(_ value: String?, into field: inout String?) {
        guard let value else { return }
        field = value.isEmpty ? nil : value
    }
}

private extension StringProtocol {
    func trimmingWhitespace() -> String {
        let scalars = unicodeScalars
        guard let first = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let last = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else {
            return ""
        }
        var trimmed = String.UnicodeScalarView()
        trimmed.append(contentsOf: scalars[first...last])
        return String(trimmed)
    }
}
