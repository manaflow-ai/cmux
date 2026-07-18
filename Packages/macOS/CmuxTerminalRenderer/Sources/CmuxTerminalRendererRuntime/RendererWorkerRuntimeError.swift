/// A bounded worker-lifecycle failure mapped to one fatal control reply.
public enum RendererWorkerRuntimeError: Error, Equatable, Sendable {
    case expectedBootstrap
    case bootstrapIdentityMismatch
    case duplicateBootstrap
    case commandAfterTermination
    case invalidPresentation
    case stalePresentationGeneration
    case unknownPresentation
    case sceneIdentityMismatch
    case releaseIdentityMismatch
    case unknownFrameLease
    case presentationLimitExceeded
    case retiredPresentationLimitExceeded
    case engine(RendererPresentationEngineError)
    case engineFailure(String)

    public var diagnostic: String {
        switch self {
        case .expectedBootstrap: "first command was not bootstrap"
        case .bootstrapIdentityMismatch: "bootstrap did not match the worker launch identity"
        case .duplicateBootstrap: "worker received a duplicate bootstrap"
        case .commandAfterTermination: "worker received a command after termination"
        case .invalidPresentation: "presentation fields cannot initialize a standalone renderer"
        case .stalePresentationGeneration: "presentation generation did not advance"
        case .unknownPresentation: "command referenced an unattached presentation"
        case .sceneIdentityMismatch: "scene did not match the current presentation lifetime"
        case .releaseIdentityMismatch: "frame release did not match worker or frame provenance"
        case .unknownFrameLease: "frame release referenced an unknown or duplicate lease"
        case .presentationLimitExceeded: "workspace presentation limit exceeded"
        case .retiredPresentationLimitExceeded: "retired presentation lease limit exceeded"
        case let .engine(value): "standalone renderer failed: \(value)"
        case let .engineFailure(value): "standalone renderer failed: \(value)"
        }
    }
}
