internal import Foundation

/// Eternal Terminal client settings for a remote workspace terminal.
///
/// SSH continues to carry daemon bootstrap, relay, proxy, and upload traffic.
/// These values only shape the local `et` invocation that carries the
/// interactive terminal, and they persist so a restored workspace reattaches
/// through the same `etserver` port and `etterminal` path.
public struct EternalTerminalOptions: Codable, Equatable, Sendable {
    /// The `etserver` port ET uses when none is given.
    public static let defaultServerPort = 2022

    /// The remote `etserver` TCP port, or `nil` for ``defaultServerPort``.
    public let serverPort: Int?

    /// Absolute remote path to `etterminal` when it is off the non-interactive `PATH`.
    public let terminalPath: String?

    /// ET `--tunnel` values, joined into ET's single comma-separated option.
    public let tunnels: [String]

    /// ET `--reversetunnel` values, joined into ET's single comma-separated option.
    public let reverseTunnels: [String]

    /// The default ET client settings.
    public static let `default` = Self(validatedServerPort: nil, terminalPath: nil, tunnels: [], reverseTunnels: [])

    /// Creates validated ET client settings.
    ///
    /// Returns `nil` for a port outside 1-65535, for a terminal path that is
    /// not absolute (a remote `~` cannot be expanded locally), for any value
    /// that is empty or contains control characters (each value becomes one
    /// argument of a terminal startup command), or for comma-separated tunnels
    /// that are not ET-style source/destination pairs. Pairs may name ports,
    /// equal-length port ranges, sockets, or environment variables. ET's
    /// four-part SSH syntax is supported only as a single tunnel without commas.
    ///
    /// - Parameters:
    ///   - serverPort: Remote `etserver` port.
    ///   - terminalPath: Remote `etterminal` path.
    ///   - tunnels: Local-to-remote ET tunnel specifications.
    ///   - reverseTunnels: Remote-to-local ET tunnel specifications.
    public init?(
        serverPort: Int? = nil,
        terminalPath: String? = nil,
        tunnels: [String] = [],
        reverseTunnels: [String] = []
    ) {
        if let serverPort, !(1...65_535).contains(serverPort) { return nil }
        let normalizedTerminalPath = terminalPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedTerminalPath,
           !normalizedTerminalPath.hasPrefix("/") || !normalizedTerminalPath.isValidEternalTerminalArgument {
            return nil
        }
        let normalizedTunnels = tunnels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let normalizedReverseTunnels = reverseTunnels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard (normalizedTunnels + normalizedReverseTunnels).allSatisfy(\.isValidEternalTerminalArgument),
              Self.canJoinTunnels(normalizedTunnels),
              Self.canJoinTunnels(normalizedReverseTunnels) else {
            return nil
        }
        self.init(
            validatedServerPort: serverPort,
            terminalPath: normalizedTerminalPath,
            tunnels: normalizedTunnels,
            reverseTunnels: normalizedReverseTunnels
        )
    }

    private static func canJoinTunnels(_ tunnels: [String]) -> Bool {
        guard tunnels.count > 1 || tunnels.first?.contains(",") == true else { return true }
        return tunnels.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }.allSatisfy { tunnel in
            let sides = tunnel.split(separator: ":", omittingEmptySubsequences: false)
            guard sides.count == 2, sides.allSatisfy({ !$0.isEmpty }) else { return false }
            let numeric = sides.map { $0.allSatisfy { $0.isASCIIDigit || $0 == "-" } }
            // ET accepts named sockets/environment variables in the same
            // comma list as numeric pairs. Socket-to-port pairs require ET 7.
            if !numeric[0] && !numeric[1] { return true }
            if sides[0].hasPrefix("/") || sides[1].hasPrefix("/") {
                let port = sides[sides[0].hasPrefix("/") ? 1 : 0]
                return !port.isEmpty && port.allSatisfy(\.isASCIIDigit) && Int(port) != nil
            }
            guard numeric.allSatisfy({ $0 }) else { return false }
            let bounds = sides.map { $0.split(separator: "-", omittingEmptySubsequences: false) }
            guard bounds[0].count == bounds[1].count, (1...2).contains(bounds[0].count),
                  bounds.flatMap({ $0 }).allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigit) && Int($0) != nil }) else {
                return false
            }
            if bounds[0].count == 1 { return true }
            // Both ranges must expand to the same number of ports.
            let source = bounds[0].compactMap { Int($0) }
            let destination = bounds[1].compactMap { Int($0) }
            return source[1] >= source[0] && destination[1] >= destination[0]
                && source[1] - source[0] == destination[1] - destination[0]
        }
    }

    /// The effective `etserver` port.
    public var effectiveServerPort: Int {
        serverPort ?? Self.defaultServerPort
    }

    /// The `et` arguments these settings select, excluding the destination.
    public var clientArguments: [String] {
        clientArguments(includingTerminalPath: true)
    }

    /// The `et` arguments these settings select, optionally without `--terminal-path`.
    ///
    /// ET parses `--tunnel` and `--reversetunnel` as single options whose last
    /// occurrence wins, so repeated values are joined with commas.
    ///
    /// - Parameter includingTerminalPath: Whether to emit the configured terminal path.
    /// - Returns: The `et` arguments, excluding the destination.
    public func clientArguments(includingTerminalPath: Bool) -> [String] {
        var arguments = ["--port", String(effectiveServerPort)]
        if includingTerminalPath, let terminalPath {
            arguments += ["--terminal-path", terminalPath]
        }
        if !tunnels.isEmpty {
            arguments += ["--tunnel", tunnels.joined(separator: ",")]
        }
        if !reverseTunnels.isEmpty {
            arguments += ["--reversetunnel", reverseTunnels.joined(separator: ",")]
        }
        return arguments
    }

    /// Decodes settings while preserving their validation invariants.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let options = Self(
            serverPort: try container.decodeIfPresent(Int.self, forKey: .serverPort),
            terminalPath: try container.decodeIfPresent(String.self, forKey: .terminalPath),
            tunnels: try container.decodeIfPresent([String].self, forKey: .tunnels) ?? [],
            reverseTunnels: try container.decodeIfPresent([String].self, forKey: .reverseTunnels) ?? []
        ) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid Eternal Terminal options"
            ))
        }
        self = options
    }

    /// Encodes the normalized settings, omitting defaults.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(serverPort, forKey: .serverPort)
        try container.encodeIfPresent(terminalPath, forKey: .terminalPath)
        if !tunnels.isEmpty { try container.encode(tunnels, forKey: .tunnels) }
        if !reverseTunnels.isEmpty { try container.encode(reverseTunnels, forKey: .reverseTunnels) }
    }

    private enum CodingKeys: String, CodingKey {
        case serverPort
        case terminalPath
        case tunnels
        case reverseTunnels
    }

    private init(validatedServerPort: Int?, terminalPath: String?, tunnels: [String], reverseTunnels: [String]) {
        serverPort = validatedServerPort
        self.terminalPath = terminalPath
        self.tunnels = tunnels
        self.reverseTunnels = reverseTunnels
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}

private extension String {
    var isValidEternalTerminalArgument: Bool {
        !isEmpty && !unicodeScalars.contains(where: { scalar in
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator:
                true
            default:
                false
            }
        })
    }
}
