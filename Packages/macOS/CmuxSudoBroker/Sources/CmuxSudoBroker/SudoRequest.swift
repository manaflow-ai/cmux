public import Foundation

/// A user-reviewed request to execute one captured shell script with sudo.
public struct SudoRequest: Codable, Sendable, Equatable {
    /// The timeout used by requests created without an explicit deadline.
    public static let defaultTimeoutSeconds = 300

    /// The largest request timeout accepted by the broker and CLI.
    public static let maximumTimeoutSeconds = 86_400

    /// The filesystem-safe request identifier.
    public let id: String

    /// The requester's explanation shown during approval.
    public let reason: String

    /// The process identifier of the requesting process.
    public let requesterPid: Int32

    /// The requesting executable name shown during approval.
    public let requesterCommand: String

    /// The CLI process generation whose liveness authorizes the pending request.
    public let requesterIdentity: SudoProcessIdentity?

    /// The working directory used by the approved script.
    public let currentDirectory: String

    /// The request creation date.
    public let createdAt: Date

    /// The bounded number of seconds the CLI waits for approval.
    public let timeoutSeconds: Int

    /// Creates a legacy sudo request without a liveness identity.
    ///
    /// The broker rejects this shape. It remains available only for decoding and
    /// presenting requests created by older cmux versions.
    ///
    /// - Parameters:
    ///   - id: A filesystem-safe request identifier.
    ///   - reason: The explanation shown to the approver.
    ///   - requesterPid: The requester's process identifier.
    ///   - requesterCommand: The requester's executable name.
    ///   - currentDirectory: The script working directory.
    ///   - createdAt: The creation date used for expiry.
    ///   - timeoutSeconds: The requested timeout, clamped to 1 through 86400.
    public init(
        id: String,
        reason: String,
        requesterPid: Int32,
        requesterCommand: String,
        currentDirectory: String,
        createdAt: Date,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) {
        self.init(
            id: id,
            reason: reason,
            requesterPid: requesterPid,
            requesterCommand: requesterCommand,
            requesterIdentity: nil,
            currentDirectory: currentDirectory,
            createdAt: createdAt,
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Creates a generation-qualified sudo request.
    ///
    /// - Parameters:
    ///   - id: A filesystem-safe request identifier.
    ///   - reason: The explanation shown to the approver.
    ///   - requesterIdentity: The requester generation captured with its executable.
    ///   - requesterCommand: The requester's executable name.
    ///   - currentDirectory: The script working directory.
    ///   - createdAt: The creation date used for expiry.
    ///   - timeoutSeconds: The requested timeout, clamped to 1 through 86400.
    public init(
        id: String,
        reason: String,
        requesterIdentity: SudoProcessIdentity,
        requesterCommand: String,
        currentDirectory: String,
        createdAt: Date,
        timeoutSeconds: Int = defaultTimeoutSeconds
    ) {
        self.init(
            id: id,
            reason: reason,
            requesterPid: requesterIdentity.processIdentifier,
            requesterCommand: requesterCommand,
            requesterIdentity: requesterIdentity,
            currentDirectory: currentDirectory,
            createdAt: createdAt,
            timeoutSeconds: timeoutSeconds
        )
    }

    private init(
        id: String,
        reason: String,
        requesterPid: Int32,
        requesterCommand: String,
        requesterIdentity: SudoProcessIdentity?,
        currentDirectory: String,
        createdAt: Date,
        timeoutSeconds: Int
    ) {
        self.id = id
        self.reason = reason
        self.requesterPid = requesterPid
        self.requesterCommand = requesterCommand
        self.requesterIdentity = requesterIdentity
        self.currentDirectory = currentDirectory
        self.createdAt = createdAt
        self.timeoutSeconds = min(Self.maximumTimeoutSeconds, max(1, timeoutSeconds))
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case reason
        case requesterPid
        case requesterCommand
        case requesterCmd
        case requesterIdentity
        case currentDirectory
        case cwd
        case createdAt
        case timeoutSeconds
    }

    /// Decodes both the legacy HQ field names and the cmux-native names.
    ///
    /// - Parameter decoder: The decoder containing persisted request metadata.
    /// - Throws: A decoding error when required fields are missing or malformed.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        reason = try container.decode(String.self, forKey: .reason)
        requesterPid = try container.decode(Int32.self, forKey: .requesterPid)
        requesterCommand = try container.decodeIfPresent(String.self, forKey: .requesterCommand)
            ?? container.decode(String.self, forKey: .requesterCmd)
        requesterIdentity = try container.decodeIfPresent(
            SudoProcessIdentity.self,
            forKey: .requesterIdentity
        )
        if let requesterIdentity,
           requesterIdentity.processIdentifier != requesterPid {
            throw DecodingError.dataCorruptedError(
                forKey: .requesterIdentity,
                in: container,
                debugDescription: "Requester identity does not match requesterPid"
            )
        }
        currentDirectory = try container.decodeIfPresent(String.self, forKey: .currentDirectory)
            ?? container.decode(String.self, forKey: .cwd)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        let decodedTimeout = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
            ?? Self.defaultTimeoutSeconds
        timeoutSeconds = min(Self.maximumTimeoutSeconds, max(1, decodedTimeout))
    }

    /// Encodes the cmux-native request schema.
    ///
    /// - Parameter encoder: The encoder receiving the canonical request fields.
    /// - Throws: An encoding error when the destination cannot accept a field.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(reason, forKey: .reason)
        try container.encode(requesterPid, forKey: .requesterPid)
        try container.encode(requesterCommand, forKey: .requesterCommand)
        try container.encodeIfPresent(requesterIdentity, forKey: .requesterIdentity)
        try container.encode(currentDirectory, forKey: .currentDirectory)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
    }

    /// The absolute approval deadline.
    public var approvalDeadline: Date {
        createdAt.addingTimeInterval(TimeInterval(timeoutSeconds))
    }
}
