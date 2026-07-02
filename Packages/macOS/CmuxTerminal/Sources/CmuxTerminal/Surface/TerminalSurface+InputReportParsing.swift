import Foundation

extension TerminalSurface {
    static func csiTerminalReportSequenceLength(
        _ scalars: [Unicode.Scalar],
        from start: Int
    ) -> Int? {
        guard start + 1 < scalars.count else {
            return nil
        }

        var cursor = start + 2
        while cursor < scalars.count {
            let value = scalars[cursor].value
            if value >= 0x40, value <= 0x7E {
                return isTerminalReportCSI(
                    scalars,
                    bodyStart: start + 2,
                    finalIndex: cursor
                ) ? cursor - start + 1 : nil
            }
            guard value >= 0x20, value <= 0x3F else {
                return nil
            }
            cursor += 1
        }
        return nil
    }

    private static func isTerminalReportCSI(
        _ scalars: [Unicode.Scalar],
        bodyStart: Int,
        finalIndex: Int
    ) -> Bool {
        var parameterEnd = bodyStart
        while parameterEnd < finalIndex,
              isCSIParameterByte(scalars[parameterEnd].value) {
            parameterEnd += 1
        }
        guard scalars[parameterEnd..<finalIndex].allSatisfy({ isCSIIntermediateByte($0.value) }) else {
            return false
        }

        let parameters = scalars[bodyStart..<parameterEnd].map(\.value)
        let intermediates = scalars[parameterEnd..<finalIndex].map(\.value)
        let final = scalars[finalIndex].value

        switch final {
        case 0x52:
            return intermediates.isEmpty && isCursorPositionReport(parameters)
        case 0x63:
            return intermediates.isEmpty && isDeviceAttributesReport(parameters)
        case 0x6E:
            return intermediates.isEmpty && startsWithQuestionMark(parameters)
        case 0x75:
            return intermediates.isEmpty && startsWithQuestionMark(parameters)
        case 0x79:
            return intermediates == [0x24] && startsWithQuestionMark(parameters)
        default:
            return false
        }
    }

    private static func isCursorPositionReport(_ parameters: [UInt32]) -> Bool {
        var fieldCount = 0
        var fieldHasDigit = false

        for parameter in parameters {
            if parameter >= 0x30, parameter <= 0x39 {
                fieldHasDigit = true
                continue
            }
            guard parameter == 0x3B, fieldHasDigit else {
                return false
            }
            fieldCount += 1
            fieldHasDigit = false
        }

        guard fieldHasDigit else { return false }
        fieldCount += 1
        return fieldCount == 2
    }

    private static func isDeviceAttributesReport(_ parameters: [UInt32]) -> Bool {
        guard let first = parameters.first else { return false }
        return first == 0x3F || first == 0x3E
    }

    private static func startsWithQuestionMark(_ parameters: [UInt32]) -> Bool {
        parameters.first == 0x3F
    }

    private static func isCSIParameterByte(_ value: UInt32) -> Bool {
        value >= 0x30 && value <= 0x3F
    }

    private static func isCSIIntermediateByte(_ value: UInt32) -> Bool {
        value >= 0x20 && value <= 0x2F
    }
}
