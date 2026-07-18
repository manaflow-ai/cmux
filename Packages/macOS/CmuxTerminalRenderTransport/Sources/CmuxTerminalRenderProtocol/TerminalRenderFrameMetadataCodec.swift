public import Foundation

/// Canonical fixed-width codec for renderer frame metadata.
public struct TerminalRenderFrameMetadataCodec: Sendable {
    private let magic: [UInt8] = [0x43, 0x4D, 0x58, 0x46]
    private let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
    private let damagePresentFlag: UInt16 = 1
    private let producerCompletedFlag: UInt16 = 1 << 1

    /// Creates a stateless metadata codec.
    public init() {}

    /// Encodes metadata into exactly ``TerminalRenderFrameProtocol/metadataLength`` bytes.
    ///
    /// - Parameter metadata: Validated frame metadata.
    /// - Returns: A canonical, network-byte-order record.
    public func encode(_ metadata: TerminalRenderFrameMetadata) -> Data {
        var writer = TerminalRenderWireWriter()
        writer.append(bytes: magic)
        writer.append(value: TerminalRenderFrameProtocol.currentVersion)
        var flags: UInt16 = metadata.damageBounds == nil ? 0 : damagePresentFlag
        if metadata.completionFence == .producerCompleted {
            flags |= producerCompletedFlag
        }
        writer.append(value: flags)
        writer.append(uuid: metadata.daemonInstanceID)
        writer.append(value: metadata.rendererEpoch)
        writer.append(uuid: metadata.terminalID)
        writer.append(value: metadata.terminalEpoch)
        writer.append(value: metadata.terminalSequence)
        writer.append(uuid: metadata.presentationID)
        writer.append(value: metadata.presentationGeneration)
        writer.append(value: metadata.frameSequence)
        writer.append(value: metadata.width)
        writer.append(value: metadata.height)
        writer.append(value: metadata.pixelFormat.rawValue)
        writer.append(value: metadata.colorSpace.rawValue)
        switch metadata.completionFence {
        case .producerCompleted:
            writer.append(bytes: Array(repeating: 0, count: 16))
            writer.append(value: UInt64(0))
        case let .sharedEvent(eventID, value):
            writer.append(uuid: eventID)
            writer.append(value: value)
        }
        writer.append(value: metadata.damageBounds?.x ?? 0)
        writer.append(value: metadata.damageBounds?.y ?? 0)
        writer.append(value: metadata.damageBounds?.width ?? 0)
        writer.append(value: metadata.damageBounds?.height ?? 0)
        writer.append(value: UInt64(0))
        precondition(writer.data.count == TerminalRenderFrameProtocol.metadataLength)
        return writer.data
    }

    /// Decodes and validates one canonical metadata record.
    ///
    /// - Parameter data: Exactly ``TerminalRenderFrameProtocol/metadataLength`` bytes.
    /// - Returns: Validated frame metadata.
    /// - Throws: ``TerminalRenderFrameProtocolError`` for malformed or unsupported data.
    public func decode(_ data: Data) throws -> TerminalRenderFrameMetadata {
        guard data.count == TerminalRenderFrameProtocol.metadataLength else {
            throw TerminalRenderFrameProtocolError.invalidWireLength
        }

        var reader = TerminalRenderWireReader(data: data)
        guard try reader.readBytes(count: magic.count) == magic else {
            throw TerminalRenderFrameProtocolError.invalidWireMagic
        }
        let version = try reader.readUInt16()
        guard version == TerminalRenderFrameProtocol.currentVersion else {
            throw TerminalRenderFrameProtocolError.unsupportedWireVersion(version)
        }
        let flags = try reader.readUInt16()
        guard flags & ~(damagePresentFlag | producerCompletedFlag) == 0 else {
            throw TerminalRenderFrameProtocolError.unsupportedWireFlags(flags)
        }

        let daemonInstanceID = try reader.readUUID()
        let rendererEpoch = try reader.readUInt64()
        let terminalID = try reader.readUUID()
        let terminalEpoch = try reader.readUInt64()
        let terminalSequence = try reader.readUInt64()
        let presentationID = try reader.readUUID()
        let presentationGeneration = try reader.readUInt64()
        let frameSequence = try reader.readUInt64()
        let width = try reader.readUInt32()
        let height = try reader.readUInt32()

        let pixelFormatRawValue = try reader.readUInt32()
        guard let pixelFormat = TerminalRenderPixelFormat(rawValue: pixelFormatRawValue) else {
            throw TerminalRenderFrameProtocolError.unsupportedPixelFormat(pixelFormatRawValue)
        }
        let colorSpaceRawValue = try reader.readUInt32()
        guard let colorSpace = TerminalRenderColorSpace(rawValue: colorSpaceRawValue) else {
            throw TerminalRenderFrameProtocolError.unsupportedColorSpace(colorSpaceRawValue)
        }

        let completionEventID = try reader.readUUID()
        let completionValue = try reader.readUInt64()
        let completionFence: TerminalRenderCompletionFence
        if flags & producerCompletedFlag != 0 {
            guard completionEventID == zeroUUID,
                  completionValue == 0 else {
                throw TerminalRenderFrameProtocolError.nonzeroReservedBytes
            }
            completionFence = .producerCompleted
        } else {
            guard completionValue > 0 else {
                throw TerminalRenderFrameProtocolError.invalidCompletionFence
            }
            completionFence = .sharedEvent(eventID: completionEventID, value: completionValue)
        }
        let damageX = try reader.readUInt32()
        let damageY = try reader.readUInt32()
        let damageWidth = try reader.readUInt32()
        let damageHeight = try reader.readUInt32()
        let reserved = try reader.readUInt64()
        guard reserved == 0, reader.isAtEnd else {
            throw TerminalRenderFrameProtocolError.nonzeroReservedBytes
        }

        let damageBounds: TerminalRenderDamageBounds?
        if flags & damagePresentFlag != 0 {
            damageBounds = try TerminalRenderDamageBounds(
                x: damageX,
                y: damageY,
                width: damageWidth,
                height: damageHeight
            )
        } else {
            guard damageX == 0, damageY == 0, damageWidth == 0, damageHeight == 0 else {
                throw TerminalRenderFrameProtocolError.nonzeroReservedBytes
            }
            damageBounds = nil
        }

        return try TerminalRenderFrameMetadata(
            daemonInstanceID: daemonInstanceID,
            rendererEpoch: rendererEpoch,
            terminalID: terminalID,
            terminalEpoch: terminalEpoch,
            terminalSequence: terminalSequence,
            presentationID: presentationID,
            presentationGeneration: presentationGeneration,
            frameSequence: frameSequence,
            width: width,
            height: height,
            pixelFormat: pixelFormat,
            colorSpace: colorSpace,
            completionFence: completionFence,
            damageBounds: damageBounds
        )
    }
}
