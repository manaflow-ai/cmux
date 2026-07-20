internal import Foundation

/// The durable program profile opened by a remote workspace terminal.
///
/// This profile is independent of both the management transport and the
/// interactive terminal transport. For example, a tmux profile may use Mosh
/// for its terminal while SSH continues to carry daemon and relay traffic.
public struct WorkspaceRemoteTerminalProfile: Codable, Equatable, Sendable {
    /// The program family launched in the remote terminal.
    public typealias Kind = WorkspaceRemoteTerminalProfileKind

    /// The default session used by `cmux mosh-tmux`.
    public static let defaultTmuxSessionName = "main"

    /// The standard interactive-shell profile.
    public static let shell = Self(validatedKind: .shell, tmuxSessionName: nil)

    /// The standard tmux profile, attached to ``defaultTmuxSessionName``.
    public static let defaultTmux = Self(
        validatedKind: .tmux,
        tmuxSessionName: defaultTmuxSessionName
    )

    /// The program family represented by this profile.
    public let kind: Kind

    /// The validated session name for a tmux profile; otherwise `nil`.
    public let tmuxSessionName: String?

    /// Creates a validated terminal profile.
    ///
    /// A missing tmux session uses ``defaultTmuxSessionName``. Session names
    /// are limited to 128 UTF-8 bytes and reject hidden/control characters and
    /// tmux target separators.
    ///
    /// - Parameters:
    ///   - kind: Program family to launch.
    ///   - tmuxSessionName: Session selected by a tmux profile.
    public init?(kind: Kind, tmuxSessionName: String? = nil) {
        switch kind {
        case .shell:
            guard tmuxSessionName.normalizedRemoteTmuxSessionName == nil else { return nil }
            self.init(validatedKind: .shell, tmuxSessionName: nil)
        case .tmux:
            let candidate = tmuxSessionName ?? Self.defaultTmuxSessionName
            guard let sessionName = candidate.validatedRemoteTmuxSessionName else { return nil }
            self.init(validatedKind: .tmux, tmuxSessionName: sessionName)
        }
    }

    /// Parses the `terminal_profile` and `terminal_tmux_session` socket values.
    ///
    /// - Parameters:
    ///   - remoteConfigurationValue: `shell`, `tmux`, or `nil` for the legacy shell default.
    ///   - tmuxSessionName: Optional named tmux session.
    public init?(remoteConfigurationValue: String?, tmuxSessionName: String?) {
        let rawKind = remoteConfigurationValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if rawKind?.isEmpty != false {
            guard tmuxSessionName.normalizedRemoteTmuxSessionName == nil else { return nil }
            self = .shell
            return
        }
        guard let kind = Kind(rawValue: rawKind!) else { return nil }
        self.init(kind: kind, tmuxSessionName: tmuxSessionName)
    }

    /// The remote argv for this profile, excluding the login-shell default.
    public var remoteCommandArguments: [String] {
        guard let tmuxSessionName else { return [] }
        return RemoteTmuxCommandBuilder(arguments: [
            "new-session", "-A", "-s", tmuxSessionName,
        ]).remoteCommandArguments
    }

    /// A shell-quoted remote command, or `nil` for the login-shell default.
    public var remoteShellCommand: String? {
        guard let tmuxSessionName else { return nil }
        return RemoteTmuxCommandBuilder(arguments: [
            "new-session", "-A", "-s", tmuxSessionName,
        ]).remoteShellCommand
    }

    /// Decodes a profile while preserving its validation invariants.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let sessionName = try container.decodeIfPresent(String.self, forKey: .tmuxSessionName)
        guard let profile = Self(kind: kind, tmuxSessionName: sessionName) else {
            throw DecodingError.dataCorruptedError(
                forKey: .tmuxSessionName,
                in: container,
                debugDescription: "Invalid remote terminal profile"
            )
        }
        self = profile
    }

    /// Encodes the normalized profile representation.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(tmuxSessionName, forKey: .tmuxSessionName)
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case tmuxSessionName
    }

    private init(validatedKind: Kind, tmuxSessionName: String?) {
        kind = validatedKind
        self.tmuxSessionName = tmuxSessionName
    }
}

private extension Optional where Wrapped == String {
    var normalizedRemoteTmuxSessionName: String? {
        let normalized = self?.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized?.isEmpty == false ? normalized : nil
    }
}

private extension String {
    var validatedRemoteTmuxSessionName: String? {
        guard let normalized = Optional(self).normalizedRemoteTmuxSessionName,
              normalized.utf8.count <= 128,
              !normalized.contains("."),
              !normalized.contains(":"),
              !normalized.unicodeScalars.contains(where: { scalar in
                  switch scalar.properties.generalCategory {
                  case .control, .format, .lineSeparator, .paragraphSeparator:
                      true
                  default:
                      false
                  }
              }) else { return nil }
        return normalized
    }
}
