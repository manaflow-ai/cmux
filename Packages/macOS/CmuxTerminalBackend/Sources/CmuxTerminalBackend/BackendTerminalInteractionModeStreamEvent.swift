internal import Foundation

/// Typed events carried only by the connection-wide interaction-mode subscription.
public enum BackendTerminalInteractionModeStreamEvent: Equatable, Sendable {
    case changed(BackendTerminalInteractionModeChanged)
    case invalidated(BackendTerminalInteractionModeInvalidated)
    case overflow
}

public extension BackendServerEvent {
    /// Decodes an interaction-mode stream event after validating its discriminator.
    func terminalInteractionModeStreamEvent() throws -> BackendTerminalInteractionModeStreamEvent {
        do {
            let data = try JSONEncoder().encode(self)
            switch name {
            case "terminal-interaction-mode-changed":
                return .changed(try JSONDecoder().decode(
                    BackendTerminalInteractionModeChanged.self,
                    from: data
                ))
            case "terminal-interaction-mode-invalidated":
                return .invalidated(try JSONDecoder().decode(
                    BackendTerminalInteractionModeInvalidated.self,
                    from: data
                ))
            case "terminal-interaction-mode-overflow":
                guard fields.isEmpty else { throw BackendProtocolError.malformedMessage }
                return .overflow
            default:
                throw BackendProtocolError.malformedMessage
            }
        } catch let error as BackendProtocolError {
            throw error
        } catch {
            throw BackendProtocolError.malformedMessage
        }
    }
}
