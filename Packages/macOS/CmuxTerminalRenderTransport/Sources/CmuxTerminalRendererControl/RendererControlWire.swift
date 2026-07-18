internal import CmuxTerminalRenderProtocol
public import Foundation

/// Stateless encoder and exact-frame decoder for renderer-control messages.
public struct RendererControlWire: Sendable {
    private static let magic: [UInt8] = [0x43, 0x4D, 0x52, 0x43]

    /// Creates a stateless renderer-control wire codec.
    public init() {}

    /// Encodes one complete length-prefixed frame in network byte order.
    ///
    /// - Parameter envelope: Validated direction, sequence, and typed message.
    /// - Returns: One complete renderer-control frame.
    /// - Throws: ``RendererControlError`` when a payload violates protocol bounds.
    public func encode(_ envelope: RendererControlEnvelope) throws -> Data {
        let type = try Self.messageType(for: envelope.message)
        guard type.direction == envelope.direction else {
            throw RendererControlError.unexpectedDirection
        }
        let payload = try Self.encodePayload(envelope.message)
        guard type.payloadLengthRange.contains(payload.count) else {
            throw RendererControlError.invalidPayloadLength
        }

        var writer = RendererControlWireWriter()
        writer.append(bytes: Self.magic)
        writer.append(value: RendererControlProtocol.currentVersion)
        writer.append(value: UInt16(RendererControlProtocol.headerLength))
        writer.append(value: envelope.direction.rawValue)
        writer.append(value: type.rawValue)
        writer.append(value: UInt16(0))
        writer.append(value: UInt32(0))
        writer.append(value: envelope.sequence)
        writer.append(value: UInt64(payload.count))
        writer.append(data: payload)
        return writer.data
    }

    /// Decodes one complete frame and rejects trailing or truncated bytes.
    ///
    /// - Parameter frame: One complete renderer-control frame.
    /// - Returns: The validated typed envelope.
    /// - Throws: ``RendererControlError`` when any field is unknown or malformed.
    public func decode(_ frame: Data) throws -> RendererControlEnvelope {
        guard frame.count >= RendererControlProtocol.headerLength else {
            throw RendererControlError.truncatedFrame
        }
        var reader = RendererControlWireReader(data: frame)
        guard try reader.readBytes(count: 4) == Self.magic else {
            throw RendererControlError.invalidMagic
        }
        let version = try reader.readUInt16()
        guard version == RendererControlProtocol.currentVersion else {
            throw RendererControlError.unsupportedVersion(version)
        }
        let headerLength = try reader.readUInt16()
        guard headerLength == RendererControlProtocol.headerLength else {
            throw RendererControlError.invalidHeaderLength(headerLength)
        }
        let directionRaw = try reader.readUInt8()
        guard let direction = RendererControlDirection(rawValue: directionRaw) else {
            throw RendererControlError.unknownDirection(directionRaw)
        }
        let typeRaw = try reader.readUInt8()
        guard let type = RendererControlMessageType(rawValue: typeRaw),
              type.direction == direction else {
            throw RendererControlError.unknownMessageType(typeRaw)
        }
        let flags = try reader.readUInt16()
        guard flags == 0 else {
            throw RendererControlError.unknownFlags(flags)
        }
        guard try reader.readUInt32() == 0 else {
            throw RendererControlError.nonzeroReserved
        }
        let sequence = try reader.readUInt64()
        let payloadLength = try reader.readUInt64()
        guard payloadLength <= UInt64(type.payloadLengthRange.upperBound),
              payloadLength >= UInt64(type.payloadLengthRange.lowerBound),
              payloadLength <= UInt64(Int.max) else {
            throw RendererControlError.invalidPayloadLength
        }
        guard reader.remainingCount == Int(payloadLength) else {
            throw reader.remainingCount < Int(payloadLength)
                ? RendererControlError.truncatedFrame
                : RendererControlError.trailingPayload
        }
        let payload = try reader.readData(count: Int(payloadLength))
        let message = try Self.decodePayload(type: type, payload: payload)
        return try RendererControlEnvelope(
            direction: direction,
            sequence: sequence,
            message: message
        )
    }

    static func inspectHeader(_ header: Data) throws -> (RendererControlDirection, UInt64, Int) {
        guard header.count == RendererControlProtocol.headerLength else {
            throw RendererControlError.truncatedFrame
        }
        var reader = RendererControlWireReader(data: header)
        guard try reader.readBytes(count: 4) == magic else {
            throw RendererControlError.invalidMagic
        }
        let version = try reader.readUInt16()
        guard version == RendererControlProtocol.currentVersion else {
            throw RendererControlError.unsupportedVersion(version)
        }
        let headerLength = try reader.readUInt16()
        guard headerLength == RendererControlProtocol.headerLength else {
            throw RendererControlError.invalidHeaderLength(headerLength)
        }
        let directionRaw = try reader.readUInt8()
        guard let direction = RendererControlDirection(rawValue: directionRaw) else {
            throw RendererControlError.unknownDirection(directionRaw)
        }
        let typeRaw = try reader.readUInt8()
        guard let type = RendererControlMessageType(rawValue: typeRaw),
              type.direction == direction else {
            throw RendererControlError.unknownMessageType(typeRaw)
        }
        let flags = try reader.readUInt16()
        guard flags == 0 else {
            throw RendererControlError.unknownFlags(flags)
        }
        guard try reader.readUInt32() == 0 else {
            throw RendererControlError.nonzeroReserved
        }
        let sequence = try reader.readUInt64()
        let payloadLength = try reader.readUInt64()
        guard payloadLength >= UInt64(type.payloadLengthRange.lowerBound),
              payloadLength <= UInt64(type.payloadLengthRange.upperBound) else {
            throw RendererControlError.invalidPayloadLength
        }
        return (direction, sequence, RendererControlProtocol.headerLength + Int(payloadLength))
    }

    private static func messageType(for message: RendererControlMessage) throws -> RendererControlMessageType {
        switch message {
        case .bootstrap:
            .bootstrap
        case .upsertPresentation:
            .upsertPresentation
        case .removePresentation:
            .removePresentation
        case .semanticScene:
            .semanticScene
        case .frameRelease:
            .frameRelease
        case .shutdown:
            .shutdown
        case .ready:
            .ready
        case .needsFullScene:
            .needsFullScene
        case .fatal:
            .fatal
        case .presentationReady:
            .presentationReady
        case .presentationRemoved:
            .presentationRemoved
        }
    }

    private static func encodePayload(_ message: RendererControlMessage) throws -> Data {
        var writer = RendererControlWireWriter()
        switch message {
        case let .bootstrap(value):
            try RendererControlValidation.validateIdentity(value.daemonInstanceID)
            try RendererControlValidation.validateIdentity(value.workspaceID)
            guard value.rendererEpoch != 0 else {
                throw RendererControlError.zeroRendererEpoch
            }
            writer.append(uuid: value.daemonInstanceID)
            writer.append(uuid: value.workspaceID)
            writer.append(value: value.rendererEpoch)
            writer.append(value: UInt64(0))

        case let .upsertPresentation(value):
            try RendererControlValidation.validateIdentity(value.terminalID)
            try RendererControlValidation.validateIdentity(value.presentationID)
            guard value.presentationGeneration != 0 else {
                throw RendererControlError.zeroPresentationGeneration
            }
            try RendererControlValidation.validateDimensions(width: value.width, height: value.height)
            try RendererControlValidation.validateScale(value.backingScaleFactor)
            let serviceName = Data(value.frameEndpoint.serviceName.utf8)
            guard !serviceName.isEmpty,
                  serviceName.count <= TerminalRenderFrameProtocol.maximumServiceNameLength,
                  !serviceName.contains(0) else {
                throw RendererControlError.invalidServiceName
            }
            guard value.frameEndpoint.capability.count == TerminalRenderFrameProtocol.capabilityLength else {
                throw RendererControlError.invalidCapabilityLength
            }
            guard value.resolvedConfig.count <= RendererControlProtocol.maximumResolvedConfigLength else {
                throw RendererControlError.resolvedConfigTooLarge
            }
            writer.append(uuid: value.terminalID)
            writer.append(value: value.terminalEpoch)
            writer.append(uuid: value.presentationID)
            writer.append(value: value.presentationGeneration)
            writer.append(value: value.width)
            writer.append(value: value.height)
            writer.append(value: value.backingScaleFactor.bitPattern)
            writer.append(value: value.pixelFormat.rawValue)
            writer.append(value: value.colorSpace.rawValue)
            writer.append(value: value.resolvedConfigRevision)
            writer.append(value: UInt16(serviceName.count))
            writer.append(value: UInt16(value.frameEndpoint.capability.count))
            writer.append(value: UInt32(0))
            writer.append(value: UInt64(value.resolvedConfig.count))
            writer.append(data: serviceName)
            writer.append(data: value.frameEndpoint.capability)
            writer.append(data: value.resolvedConfig)

        case let .removePresentation(value):
            writer.append(uuid: value.terminalID)
            writer.append(value: value.terminalEpoch)
            writer.append(uuid: value.presentationID)
            writer.append(value: value.presentationGeneration)
            writer.append(value: UInt64(0))

        case let .semanticScene(value):
            guard value.bytes.count <= RendererControlProtocol.maximumSemanticSceneLength else {
                throw RendererControlError.semanticSceneTooLarge
            }
            writer.append(uuid: value.terminalID)
            writer.append(value: value.terminalEpoch)
            writer.append(uuid: value.presentationID)
            writer.append(value: value.presentationGeneration)
            writer.append(value: value.canonicalSequence)
            writer.append(value: value.presentationSequence)
            writer.append(value: UInt64(value.bytes.count))
            writer.append(value: UInt64(0))
            writer.append(data: value.bytes)

        case let .frameRelease(value):
            writer.append(uuid: value.daemonInstanceID)
            writer.append(value: value.rendererEpoch)
            writer.append(uuid: value.terminalID)
            writer.append(value: value.terminalEpoch)
            writer.append(value: value.terminalSequence)
            writer.append(uuid: value.presentationID)
            writer.append(value: value.presentationGeneration)
            writer.append(value: value.frameSequence)
            writer.append(value: value.surfaceID)
            writer.append(value: UInt32(0))

        case .shutdown:
            writer.append(value: UInt64(0))

        case let .ready(value):
            guard value.processID != 0 else {
                throw RendererControlError.invalidProcessIdentity
            }
            try RendererControlValidation.validateCapabilities(value.sceneCapabilities)
            writer.append(value: value.processID)
            writer.append(value: value.effectiveUserID)
            writer.append(value: value.sceneCapabilities.rawValue)
            writer.append(value: UInt64(0))

        case let .needsFullScene(value):
            writer.append(uuid: value.terminalID)
            writer.append(value: value.terminalEpoch)
            writer.append(uuid: value.presentationID)
            writer.append(value: value.presentationGeneration)
            writer.append(value: value.lastCanonicalSequence)
            writer.append(value: value.lastPresentationSequence)
            writer.append(value: value.reason.rawValue)
            writer.append(value: UInt32(0))

        case let .fatal(value):
            let diagnostic = Data(value.diagnostic.utf8)
            guard diagnostic.count <= RendererControlProtocol.maximumDiagnosticLength else {
                throw RendererControlError.diagnosticTooLarge
            }
            writer.append(value: value.code.rawValue)
            writer.append(value: UInt32(diagnostic.count))
            writer.append(value: UInt64(0))
            writer.append(data: diagnostic)

        case let .presentationReady(value):
            writer.append(uuid: value.terminalID)
            writer.append(value: value.terminalEpoch)
            writer.append(uuid: value.presentationID)
            writer.append(value: value.presentationGeneration)
            writer.append(value: value.canonicalSequence)
            writer.append(value: value.presentationSequence)
            writer.append(value: value.columns)
            writer.append(value: value.rows)
            writer.append(value: value.cellWidth)
            writer.append(value: value.cellHeight)
            writer.append(value: value.paddingTop)
            writer.append(value: value.paddingRight)
            writer.append(value: value.paddingBottom)
            writer.append(value: value.paddingLeft)
            writer.append(value: UInt64(0))

        case let .presentationRemoved(value):
            writer.append(uuid: value.terminalID)
            writer.append(value: value.terminalEpoch)
            writer.append(uuid: value.presentationID)
            writer.append(value: value.presentationGeneration)
            writer.append(value: UInt64(0))
        }
        return writer.data
    }

    private static func decodePayload(
        type: RendererControlMessageType,
        payload: Data
    ) throws -> RendererControlMessage {
        var reader = RendererControlWireReader(data: payload)
        let message: RendererControlMessage
        switch type {
        case .bootstrap:
            let daemonInstanceID = try reader.readUUID()
            let workspaceID = try reader.readUUID()
            let rendererEpoch = try reader.readUInt64()
            try requireReservedZero(try reader.readUInt64())
            message = .bootstrap(try RendererBootstrap(
                daemonInstanceID: daemonInstanceID,
                workspaceID: workspaceID,
                rendererEpoch: rendererEpoch
            ))

        case .upsertPresentation:
            let terminalID = try reader.readUUID()
            let terminalEpoch = try reader.readUInt64()
            let presentationID = try reader.readUUID()
            let generation = try reader.readUInt64()
            let width = try reader.readUInt32()
            let height = try reader.readUInt32()
            let scale = Double(bitPattern: try reader.readUInt64())
            let pixelFormatRaw = try reader.readUInt32()
            guard let pixelFormat = TerminalRenderPixelFormat(rawValue: pixelFormatRaw) else {
                throw RendererControlError.unknownPixelFormat(pixelFormatRaw)
            }
            let colorSpaceRaw = try reader.readUInt32()
            guard let colorSpace = TerminalRenderColorSpace(rawValue: colorSpaceRaw) else {
                throw RendererControlError.unknownColorSpace(colorSpaceRaw)
            }
            let configRevision = try reader.readUInt64()
            let serviceLength = Int(try reader.readUInt16())
            let capabilityLength = Int(try reader.readUInt16())
            try requireReservedZero(try reader.readUInt32())
            let configLength = try reader.readUInt64()
            guard serviceLength > 0,
                  serviceLength <= TerminalRenderFrameProtocol.maximumServiceNameLength else {
                throw RendererControlError.invalidServiceName
            }
            guard capabilityLength == TerminalRenderFrameProtocol.capabilityLength else {
                throw RendererControlError.invalidCapabilityLength
            }
            guard configLength <= UInt64(RendererControlProtocol.maximumResolvedConfigLength),
                  UInt64(reader.remainingCount) == UInt64(serviceLength + capabilityLength) + configLength else {
                throw configLength > UInt64(RendererControlProtocol.maximumResolvedConfigLength)
                    ? RendererControlError.resolvedConfigTooLarge
                    : RendererControlError.invalidPayloadLength
            }
            let serviceData = try reader.readData(count: serviceLength)
            guard let serviceName = String(data: serviceData, encoding: .utf8),
                  !serviceName.utf8.contains(0) else {
                throw RendererControlError.invalidServiceName
            }
            let capability = try reader.readData(count: capabilityLength)
            let config = try reader.readData(count: Int(configLength))
            let endpoint: TerminalRenderFrameEndpoint
            do {
                endpoint = try TerminalRenderFrameEndpoint(
                    serviceName: serviceName,
                    capability: capability
                )
            } catch {
                throw RendererControlError.invalidServiceName
            }
            message = .upsertPresentation(try RendererPresentationAttachment(
                terminalID: terminalID,
                terminalEpoch: terminalEpoch,
                presentationID: presentationID,
                presentationGeneration: generation,
                width: width,
                height: height,
                backingScaleFactor: scale,
                pixelFormat: pixelFormat,
                colorSpace: colorSpace,
                frameEndpoint: endpoint,
                resolvedConfigRevision: configRevision,
                resolvedConfig: config
            ))

        case .removePresentation:
            let terminalID = try reader.readUUID()
            let terminalEpoch = try reader.readUInt64()
            let presentationID = try reader.readUUID()
            let generation = try reader.readUInt64()
            try requireReservedZero(try reader.readUInt64())
            message = .removePresentation(try RendererPresentationRemoval(
                terminalID: terminalID,
                terminalEpoch: terminalEpoch,
                presentationID: presentationID,
                presentationGeneration: generation
            ))

        case .semanticScene:
            let terminalID = try reader.readUUID()
            let terminalEpoch = try reader.readUInt64()
            let presentationID = try reader.readUUID()
            let generation = try reader.readUInt64()
            let canonicalSequence = try reader.readUInt64()
            let presentationSequence = try reader.readUInt64()
            let sceneLength = try reader.readUInt64()
            try requireReservedZero(try reader.readUInt64())
            guard sceneLength <= UInt64(RendererControlProtocol.maximumSemanticSceneLength) else {
                throw RendererControlError.semanticSceneTooLarge
            }
            guard sceneLength == UInt64(reader.remainingCount) else {
                throw RendererControlError.invalidPayloadLength
            }
            message = .semanticScene(try RendererSemanticScene(
                terminalID: terminalID,
                terminalEpoch: terminalEpoch,
                presentationID: presentationID,
                presentationGeneration: generation,
                canonicalSequence: canonicalSequence,
                presentationSequence: presentationSequence,
                bytes: try reader.readData(count: Int(sceneLength))
            ))

        case .frameRelease:
            let daemonInstanceID = try reader.readUUID()
            let rendererEpoch = try reader.readUInt64()
            let terminalID = try reader.readUUID()
            let terminalEpoch = try reader.readUInt64()
            let terminalSequence = try reader.readUInt64()
            let presentationID = try reader.readUUID()
            let generation = try reader.readUInt64()
            let frameSequence = try reader.readUInt64()
            let surfaceID = try reader.readUInt32()
            try requireReservedZero(try reader.readUInt32())
            message = .frameRelease(try RendererControlFrameRelease(
                daemonInstanceID: daemonInstanceID,
                rendererEpoch: rendererEpoch,
                terminalID: terminalID,
                terminalEpoch: terminalEpoch,
                terminalSequence: terminalSequence,
                presentationID: presentationID,
                presentationGeneration: generation,
                frameSequence: frameSequence,
                surfaceID: surfaceID
            ))

        case .shutdown:
            try requireReservedZero(try reader.readUInt64())
            message = .shutdown

        case .ready:
            let processID = try reader.readUInt32()
            let effectiveUserID = try reader.readUInt32()
            let capabilities = RendererSceneCapabilities(rawValue: try reader.readUInt64())
            try requireReservedZero(try reader.readUInt64())
            message = .ready(try RendererWorkerReady(
                processID: processID,
                effectiveUserID: effectiveUserID,
                sceneCapabilities: capabilities
            ))

        case .needsFullScene:
            let terminalID = try reader.readUUID()
            let terminalEpoch = try reader.readUInt64()
            let presentationID = try reader.readUUID()
            let generation = try reader.readUInt64()
            let canonicalSequence = try reader.readUInt64()
            let presentationSequence = try reader.readUInt64()
            let reasonRaw = try reader.readUInt32()
            guard let reason = RendererNeedsFullSceneReason(rawValue: reasonRaw) else {
                throw RendererControlError.unknownNeedsFullSceneReason(reasonRaw)
            }
            try requireReservedZero(try reader.readUInt32())
            message = .needsFullScene(try RendererNeedsFullScene(
                terminalID: terminalID,
                terminalEpoch: terminalEpoch,
                presentationID: presentationID,
                presentationGeneration: generation,
                lastCanonicalSequence: canonicalSequence,
                lastPresentationSequence: presentationSequence,
                reason: reason
            ))

        case .fatal:
            let codeRaw = try reader.readUInt32()
            guard let code = RendererFatalCode(rawValue: codeRaw) else {
                throw RendererControlError.unknownFatalCode(codeRaw)
            }
            let diagnosticLength = Int(try reader.readUInt32())
            try requireReservedZero(try reader.readUInt64())
            guard diagnosticLength <= RendererControlProtocol.maximumDiagnosticLength else {
                throw RendererControlError.diagnosticTooLarge
            }
            guard diagnosticLength == reader.remainingCount else {
                throw RendererControlError.invalidPayloadLength
            }
            let diagnosticData = try reader.readData(count: diagnosticLength)
            guard let diagnostic = String(data: diagnosticData, encoding: .utf8) else {
                throw RendererControlError.invalidUTF8
            }
            message = .fatal(try RendererFatal(code: code, diagnostic: diagnostic))

        case .presentationReady:
            let terminalID = try reader.readUUID()
            let terminalEpoch = try reader.readUInt64()
            let presentationID = try reader.readUUID()
            let generation = try reader.readUInt64()
            let canonicalSequence = try reader.readUInt64()
            let presentationSequence = try reader.readUInt64()
            let columns = try reader.readUInt32()
            let rows = try reader.readUInt32()
            let cellWidth = try reader.readUInt32()
            let cellHeight = try reader.readUInt32()
            let paddingTop = try reader.readUInt32()
            let paddingRight = try reader.readUInt32()
            let paddingBottom = try reader.readUInt32()
            let paddingLeft = try reader.readUInt32()
            try requireReservedZero(try reader.readUInt64())
            message = .presentationReady(try RendererPresentationReady(
                terminalID: terminalID,
                terminalEpoch: terminalEpoch,
                presentationID: presentationID,
                presentationGeneration: generation,
                canonicalSequence: canonicalSequence,
                presentationSequence: presentationSequence,
                columns: columns,
                rows: rows,
                cellWidth: cellWidth,
                cellHeight: cellHeight,
                paddingTop: paddingTop,
                paddingRight: paddingRight,
                paddingBottom: paddingBottom,
                paddingLeft: paddingLeft
            ))

        case .presentationRemoved:
            let terminalID = try reader.readUUID()
            let terminalEpoch = try reader.readUInt64()
            let presentationID = try reader.readUUID()
            let presentationGeneration = try reader.readUInt64()
            try requireReservedZero(try reader.readUInt64())
            message = .presentationRemoved(try RendererPresentationRemoved(
                terminalID: terminalID,
                terminalEpoch: terminalEpoch,
                presentationID: presentationID,
                presentationGeneration: presentationGeneration
            ))
        }
        guard reader.isAtEnd else {
            throw RendererControlError.trailingPayload
        }
        return message
    }

    private static func requireReservedZero<T: FixedWidthInteger>(_ value: T) throws {
        guard value == 0 else {
            throw RendererControlError.nonzeroReserved
        }
    }
}
