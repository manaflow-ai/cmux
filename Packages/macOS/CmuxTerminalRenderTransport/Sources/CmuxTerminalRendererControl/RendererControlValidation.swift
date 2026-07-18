internal import CmuxTerminalRenderProtocol
internal import Foundation

/// Shared value validation used by constructors and the wire codec.
enum RendererControlValidation {
    static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    static func validateIdentity(_ value: UUID) throws {
        guard value != zeroUUID else {
            throw RendererControlError.zeroIdentity
        }
    }

    static func validateDimensions(width: UInt32, height: UInt32) throws {
        guard width > 0,
              height > 0,
              width <= TerminalRenderFrameProtocol.maximumDimension,
              height <= TerminalRenderFrameProtocol.maximumDimension,
              UInt64(width) * UInt64(height) <= TerminalRenderFrameProtocol.maximumPixelCount else {
            throw RendererControlError.invalidDimensions
        }
    }

    static func validateScale(_ value: Double) throws {
        guard value.isFinite,
              value > 0,
              value <= RendererControlProtocol.maximumBackingScaleFactor else {
            throw RendererControlError.invalidScale
        }
    }

    static func validateCapabilities(_ capabilities: RendererSceneCapabilities) throws {
        let unknown = capabilities.rawValue & ~RendererSceneCapabilities.allKnown.rawValue
        guard unknown == 0, capabilities.contains(.fullScene) else {
            throw RendererControlError.unknownSceneCapabilities(capabilities.rawValue)
        }
    }
}
