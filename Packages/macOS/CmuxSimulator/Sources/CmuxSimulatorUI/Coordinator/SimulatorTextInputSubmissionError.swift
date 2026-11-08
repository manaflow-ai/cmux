import CmuxSimulator
import Foundation

/// Failures returned synchronously before or while queueing native text input.
public enum SimulatorTextInputSubmissionError: Error, Equatable, Sendable {
    /// The text cannot be represented by the Simulator keyboard transport.
    case encoding(SimulatorTextInputEncodingError)
    /// The selected Simulator cannot currently receive input.
    case inputUnavailable
    /// The isolated worker could not accept the input request.
    case deliveryUnavailable

    var failure: SimulatorFailure {
        switch self {
        case .encoding(.empty):
            return SimulatorFailure(
                code: "text_input_empty",
                message: String(
                    localized: "simulator.failure.textEmpty",
                    defaultValue: "Enter text to type"
                ),
                isRecoverable: true
            )
        case let .encoding(.tooLong(_, maximum)):
            return SimulatorFailure(
                code: "text_input_too_long",
                message: String(
                    localized: "simulator.failure.textTooLongDetail",
                    defaultValue: "Text is too long to type (maximum \(maximum) UTF-8 bytes)"
                ),
                isRecoverable: true
            )
        case let .encoding(.unsupportedScalar(value, index)):
            return SimulatorFailure(
                code: "text_input_unsupported_character",
                message: String(
                    localized: "simulator.failure.textUnsupportedDetail",
                    defaultValue: "Text contains a character that cannot be typed with a US keyboard (scalar \(index): U+\(String(value, radix: 16, uppercase: true)))"
                ),
                isRecoverable: true
            )
        case .encoding(.malformedSequence), .deliveryUnavailable:
            return SimulatorFailure(
                code: "text_input_delivery_unavailable",
                message: String(
                    localized: "simulator.failure.inputUnavailable",
                    defaultValue: "Simulator input is unavailable"
                ),
                isRecoverable: true
            )
        case .inputUnavailable:
            return SimulatorFailure(
                code: "input_unavailable",
                message: String(
                    localized: "simulator.failure.inputUnavailable",
                    defaultValue: "Simulator input is unavailable"
                ),
                isRecoverable: true
            )
        }
    }
}
