public import Foundation

/// Stable logical-client identity paired with one process-launch identity.
public struct BackendClientRegistrationIdentity: Equatable, Sendable {
    public let clientUUID: UUID
    public let processInstanceUUID: UUID

    public init?(clientUUID: UUID, processInstanceUUID: UUID) {
        guard clientUUID != Self.nilUUID, processInstanceUUID != Self.nilUUID else { return nil }
        self.clientUUID = clientUUID
        self.processInstanceUUID = processInstanceUUID
    }

    private static let nilUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

/// Protocol version selected for terminal mutation on one exact connection.
public enum BackendTerminalControlProtocol: UInt32, Equatable, Sendable {
    case legacyV8 = 8
    case leasedV9 = 9
}

/// The server-echoed registration fence for one transport connection.
public struct BackendClientRegistration: Decodable, Equatable, Sendable {
    public let protocolVersion: UInt32
    public let connectionID: UUID
    public let clientUUID: UUID
    public let processInstanceUUID: UUID

    private enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case connectionID = "connection_id"
        case clientUUID = "client_uuid"
        case processInstanceUUID = "process_instance_uuid"
    }
}

/// Independent protocol-v9 terminal authority lanes.
public enum BackendTerminalLeaseKind: String, Codable, Equatable, Sendable {
    case input
    case geometry
}

/// A connection-bound lease over one operation lane of a visible presentation.
public struct BackendTerminalLease: Equatable, Sendable {
    public let connectionID: UUID
    public let kind: BackendTerminalLeaseKind
    public let surfaceID: SurfaceID
    public let presentationID: PresentationID
    public let presentationGeneration: UInt64
    public let leaseID: UUID
    public let leaseGeneration: UInt64
    public let revocationSequence: UInt64
    public let expiresAtMilliseconds: UInt64
    public let nextSequence: UInt64
    public let nextGlobalInputSequence: UInt64?
    public let migratedFromLegacy: Bool

    internal init(
        connectionID: UUID,
        response: BackendTerminalLeaseResponse
    ) {
        self.connectionID = connectionID
        kind = response.kind
        surfaceID = response.surfaceID
        presentationID = response.presentationID
        presentationGeneration = response.presentationGeneration
        leaseID = response.leaseID
        leaseGeneration = response.leaseGeneration
        revocationSequence = response.revocationSequence
        expiresAtMilliseconds = response.expiresAtMilliseconds
        nextSequence = response.nextSequence
        nextGlobalInputSequence = response.nextGlobalInputSequence
        migratedFromLegacy = response.migratedFromLegacy
    }
}

/// The independently refreshable input and geometry authorities for one presentation.
public struct BackendTerminalControlLease: Equatable, Sendable {
    public let input: BackendTerminalLease
    public let geometry: BackendTerminalLease

    public var connectionID: UUID { input.connectionID }
    public var nextInputSequence: UInt64 { input.nextSequence }
    public var nextGeometrySequence: UInt64 { geometry.nextSequence }
    public var migratedFromLegacy: Bool {
        input.migratedFromLegacy || geometry.migratedFromLegacy
    }

    internal init(input: BackendTerminalLease, geometry: BackendTerminalLease) {
        self.input = input
        self.geometry = geometry
    }
}

internal struct BackendTerminalLeaseResponse: Decodable, Equatable, Sendable {
    let kind: BackendTerminalLeaseKind
    let surfaceID: SurfaceID
    let presentationID: PresentationID
    let presentationGeneration: UInt64
    let leaseID: UUID
    let leaseGeneration: UInt64
    let revocationSequence: UInt64
    let expiresAtMilliseconds: UInt64
    let nextSequence: UInt64
    let nextGlobalInputSequence: UInt64?
    let migratedFromLegacy: Bool

    private enum CodingKeys: String, CodingKey {
        case kind
        case surfaceID = "surface_uuid"
        case presentationID = "presentation_id"
        case presentationGeneration = "presentation_generation"
        case leaseID = "lease_id"
        case leaseGeneration = "lease_generation"
        case revocationSequence = "revocation_sequence"
        case expiresAtMilliseconds = "expires_at_ms"
        case nextSequence = "next_sequence"
        case nextGlobalInputSequence = "next_global_input_sequence"
        case migratedFromLegacy = "migrated_from_legacy"
    }
}

/// One contiguous input lifecycle. The daemon rejects interleaving callers.
public struct BackendTerminalInputGroup: Equatable, Sendable {
    public let id: UUID
    public let index: UInt32
    public let end: Bool

    public init(id: UUID, index: UInt32, end: Bool) {
        self.id = id
        self.index = index
        self.end = end
    }
}

public enum BackendTerminalAutomationInputScope: String, Codable, Hashable, Sendable {
    case text
    case key
    case mouse
}

public struct BackendTerminalInputDelegation: Decodable, Equatable, Sendable {
    public let surfaceID: SurfaceID
    public let delegationID: UUID
    public let delegationGeneration: UInt64
    public let ownerLeaseGeneration: UInt64
    public let delegateClientUUID: UUID
    public let delegateProcessInstanceUUID: UUID
    public let expiresAtMilliseconds: UInt64
    public let scopes: Set<BackendTerminalAutomationInputScope>
    public let nextSequence: UInt64

    private enum CodingKeys: String, CodingKey {
        case surfaceID = "surface_uuid"
        case delegationID = "delegation_id"
        case delegationGeneration = "delegation_generation"
        case ownerLeaseGeneration = "owner_lease_generation"
        case delegateClientUUID = "delegate_client_uuid"
        case delegateProcessInstanceUUID = "delegate_process_instance_uuid"
        case expiresAtMilliseconds = "expires_at_ms"
        case scopes
        case nextSequence = "next_sequence"
    }
}

/// Renderer-resolved terminal cell coordinates for one pointer event.
public enum BackendTerminalMouseAutoscroll: String, Equatable, Sendable {
    case up
    case down
}

public struct BackendTerminalCellMouseEvent: Equatable, Sendable {
    public let action: BackendTerminalMouseAction
    public let button: BackendTerminalMouseButton?
    public let modifiers: UInt16
    public let column: UInt16
    public let row: UInt16
    public let anyButtonPressed: Bool
    public let clickCount: UInt8
    public let autoscroll: BackendTerminalMouseAutoscroll?

    public init(
        action: BackendTerminalMouseAction,
        button: BackendTerminalMouseButton? = nil,
        modifiers: UInt16 = 0,
        column: UInt16,
        row: UInt16,
        anyButtonPressed: Bool = false,
        clickCount: UInt8 = 1,
        autoscroll: BackendTerminalMouseAutoscroll? = nil
    ) {
        self.action = action
        self.button = button
        self.modifiers = modifiers
        self.column = column
        self.row = row
        self.anyButtonPressed = anyButtonPressed
        self.clickCount = clickCount
        self.autoscroll = autoscroll
    }

    /// Resolves host pixels against renderer-owned metrics, clamping padding and edges.
    public init?(
        action: BackendTerminalMouseAction,
        button: BackendTerminalMouseButton? = nil,
        modifiers: UInt16 = 0,
        x: Double,
        y: Double,
        columns: UInt16,
        rows: UInt16,
        cellWidth: UInt32,
        cellHeight: UInt32,
        padding: BackendRendererPadding,
        anyButtonPressed: Bool = false,
        clickCount: UInt32 = 1
    ) {
        guard x.isFinite,
              y.isFinite,
              columns > 0,
              rows > 0,
              cellWidth > 0,
              cellHeight > 0,
              (1 ... 3).contains(clickCount)
        else { return nil }

        let localX = max(x - Double(padding.left), 0)
        let localY = max(y - Double(padding.top), 0)
        let resolvedColumn = min(
            floor(localX / Double(cellWidth)),
            Double(columns - 1)
        )
        let resolvedRow = min(
            floor(localY / Double(cellHeight)),
            Double(rows - 1)
        )
        let gridBottom = Double(padding.top) + Double(rows) * Double(cellHeight)
        let autoscroll: BackendTerminalMouseAutoscroll? = if action == .motion,
                                                            anyButtonPressed {
            if y < Double(padding.top) {
                .up
            } else if y >= gridBottom {
                .down
            } else {
                nil
            }
        } else {
            nil
        }
        self.init(
            action: action,
            button: button,
            modifiers: modifiers,
            column: UInt16(resolvedColumn),
            row: UInt16(resolvedRow),
            anyButtonPressed: anyButtonPressed,
            clickCount: UInt8(clickCount),
            autoscroll: autoscroll
        )
    }
}

/// A typed operation encoded by the daemon against canonical Ghostty terminal modes.
public enum BackendTerminalControlInput: Equatable, Sendable {
    case text(String, paste: Bool)
    case bytes(Data, paste: Bool)
    case namedKey(String)
    case key(BackendTerminalKeyEvent)
    case mouse(BackendTerminalCellMouseEvent)

    internal var jsonValue: BackendJSONValue {
        switch self {
        case .text(let text, let paste):
            return .object([
                "type": .string("text"),
                "text": .string(text),
                "paste": .bool(paste),
            ])
        case .bytes(let data, let paste):
            return .object([
                "type": .string("bytes"),
                "data": .string(data.base64EncodedString()),
                "paste": .bool(paste),
            ])
        case .namedKey(let key):
            return .object([
                "type": .string("named-key"),
                "key": .string(key),
            ])
        case .key(let event):
            return .object([
                "type": .string("key"),
                "key": .unsignedInteger(UInt64(event.key)),
                "modifiers": .unsignedInteger(UInt64(event.modifiers)),
                "consumed_modifiers": .unsignedInteger(UInt64(event.consumedModifiers)),
                "text": .string(event.text),
                "unshifted_codepoint": .unsignedInteger(UInt64(event.unshiftedCodepoint)),
                "action": .string(event.action.rawValue),
            ])
        case .mouse(let event):
            var value: [String: BackendJSONValue] = [
                "type": .string("mouse"),
                "action": .string(event.action.rawValue),
                "modifiers": .unsignedInteger(UInt64(event.modifiers)),
                "column": .unsignedInteger(UInt64(event.column)),
                "row": .unsignedInteger(UInt64(event.row)),
                "any_button_pressed": .bool(event.anyButtonPressed),
                "click_count": .unsignedInteger(UInt64(event.clickCount)),
            ]
            if let button = event.button {
                value["button"] = .string(button.rawValue)
            }
            if let autoscroll = event.autoscroll {
                value["autoscroll"] = .string(autoscroll.rawValue)
            }
            return .object(value)
        }
    }
}

public enum BackendTerminalOperationKind: String, Decodable, Equatable, Sendable {
    case input
    case geometry
}

public enum BackendTerminalOperationStatus: String, Decodable, Equatable, Sendable {
    case applied
    case indeterminate
    case unknown
}

/// Idempotency receipt for an ordered terminal input or geometry mutation.
public struct BackendTerminalOperationReceipt: Decodable, Equatable, Sendable {
    public let requestID: UUID
    public let status: BackendTerminalOperationStatus
    public let kind: BackendTerminalOperationKind?
    public let sequence: UInt64?
    public let orderedInputSequence: UInt64?
    public let leaseGeneration: UInt64?
    public let replayed: Bool?
    public let encodedBytes: UInt64?
    public let columns: UInt16?
    public let rows: UInt16?
    public let changed: Bool?
    public let diagnostic: String?
    public let leaseRevoked: Bool?

    private enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case status
        case kind
        case sequence
        case orderedInputSequence = "ordered_input_sequence"
        case leaseGeneration = "lease_generation"
        case replayed
        case encodedBytes = "encoded_bytes"
        case columns = "cols"
        case rows
        case changed
        case diagnostic
        case leaseRevoked = "lease_revoked"
    }
}

/// Failures specific to protocol-v9 connection and lease fencing.
public enum BackendTerminalControlError: Error, Equatable, Sendable {
    case protocolNotNegotiated
    case unsupportedProtocol(UInt32)
    case registrationIdentityMismatch
    case staleConnection
    case leaseUnavailable
    case staleLease
    case inputGroupConflict
    case indeterminate(requestID: UUID, diagnostic: String)
}
