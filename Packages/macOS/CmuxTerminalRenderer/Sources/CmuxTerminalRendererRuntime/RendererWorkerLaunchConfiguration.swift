internal import Foundation

public enum RendererWorkerLaunchConfigurationError: Error, Equatable, Sendable {
    case missingWorkspace
    case invalidWorkspace
    case missingRendererEpoch
    case invalidRendererEpoch
    case duplicateArgument(String)
    case unknownArgument(String)
    case missingControlDescriptor
    case invalidControlDescriptor
    case missingDaemonInstance
    case invalidDaemonInstance
}

/// Strict worker launch arguments and inherited control descriptor.
public struct RendererWorkerLaunchConfiguration: Equatable, Sendable {
    public let expectation: RendererWorkerExpectation
    public let controlDescriptor: Int32

    public init(
        arguments: [String],
        environment: [String: String]
    ) throws {
        var workspace: UUID?
        var rendererEpoch: UInt64?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            guard index + 1 < arguments.count else {
                throw RendererWorkerLaunchConfigurationError.unknownArgument(argument)
            }
            let value = arguments[index + 1]
            switch argument {
            case "--workspace":
                guard workspace == nil else {
                    throw RendererWorkerLaunchConfigurationError.duplicateArgument(argument)
                }
                guard let parsed = UUID(uuidString: value), parsed != Self.zeroUUID else {
                    throw RendererWorkerLaunchConfigurationError.invalidWorkspace
                }
                workspace = parsed
            case "--renderer-epoch":
                guard rendererEpoch == nil else {
                    throw RendererWorkerLaunchConfigurationError.duplicateArgument(argument)
                }
                guard let parsed = UInt64(value), parsed != 0 else {
                    throw RendererWorkerLaunchConfigurationError.invalidRendererEpoch
                }
                rendererEpoch = parsed
            default:
                throw RendererWorkerLaunchConfigurationError.unknownArgument(argument)
            }
            index += 2
        }
        guard let workspace else {
            throw RendererWorkerLaunchConfigurationError.missingWorkspace
        }
        guard let rendererEpoch else {
            throw RendererWorkerLaunchConfigurationError.missingRendererEpoch
        }
        guard let descriptorText = environment["CMUX_RENDERER_CONTROL_FD"] else {
            throw RendererWorkerLaunchConfigurationError.missingControlDescriptor
        }
        guard let descriptor = Int32(descriptorText), descriptor >= 3 else {
            throw RendererWorkerLaunchConfigurationError.invalidControlDescriptor
        }
        guard let daemonText = environment["CMUX_DAEMON_INSTANCE_ID"] else {
            throw RendererWorkerLaunchConfigurationError.missingDaemonInstance
        }
        guard let daemonInstanceID = UUID(uuidString: daemonText),
              daemonInstanceID != Self.zeroUUID else {
            throw RendererWorkerLaunchConfigurationError.invalidDaemonInstance
        }
        self.expectation = RendererWorkerExpectation(
            daemonInstanceID: daemonInstanceID,
            workspaceID: workspace,
            rendererEpoch: rendererEpoch
        )
        self.controlDescriptor = descriptor
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
