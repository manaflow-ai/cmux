import SwiftUI

enum LargeTextSelectionPolicy {
    enum Mode: Equatable {
        case liveSelection
        case copyOnly
    }

    static let defaultMaximumLiveSelectionLineFragments = 2_000
    static let defaultEstimatedColumnsPerWrappedLine = 48
    static let defaultCharactersPerWrappedLine = defaultEstimatedColumnsPerWrappedLine

    nonisolated static func mode(
        for text: String,
        charactersPerWrappedLine: Int = defaultCharactersPerWrappedLine,
        maximumLineFragments: Int = defaultMaximumLiveSelectionLineFragments
    ) -> Mode {
        guard charactersPerWrappedLine > 0, maximumLineFragments > 0 else {
            return .copyOnly
        }

        var lineFragments = 0
        var currentLineEstimatedColumns = 0
        var sawAnyCharacter = false
        var previousCharacterWasLineBreak = false
        var previousCharacterWasCarriageReturn = false

        func appendLineFragment() -> Bool {
            currentLineEstimatedColumns = 0
            lineFragments += 1
            return lineFragments <= maximumLineFragments
        }

        for scalar in text.unicodeScalars {
            sawAnyCharacter = true
            if isLineBreak(scalar) {
                if scalar.value == 0x0A, previousCharacterWasCarriageReturn {
                    previousCharacterWasCarriageReturn = false
                    continue
                }
                if currentLineEstimatedColumns > 0 || previousCharacterWasLineBreak || lineFragments == 0 {
                    guard appendLineFragment() else { return .copyOnly }
                }
                previousCharacterWasLineBreak = true
                previousCharacterWasCarriageReturn = scalar.value == 0x0D
            } else {
                previousCharacterWasLineBreak = false
                previousCharacterWasCarriageReturn = false
                currentLineEstimatedColumns += estimatedDisplayColumns(for: scalar)
                if currentLineEstimatedColumns >= charactersPerWrappedLine {
                    guard appendLineFragment() else { return .copyOnly }
                }
            }
        }

        if currentLineEstimatedColumns > 0 || !sawAnyCharacter || previousCharacterWasLineBreak {
            guard appendLineFragment() else { return .copyOnly }
        }
        return .liveSelection
    }

    private nonisolated static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029:
            return true
        default:
            return false
        }
    }

    private nonisolated static func estimatedDisplayColumns(for scalar: Unicode.Scalar) -> Int {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark:
            return 0
        default:
            break
        }

        switch scalar.value {
        case 0x200D, 0xFE00...0xFE0F:
            return 0
        case 0x1100...0x115F,
             0x231A...0x231B,
             0x2329...0x232A,
             0x23E9...0x23EC,
             0x23F0,
             0x23F3,
             0x25FD...0x25FE,
             0x2614...0x2615,
             0x2648...0x2653,
             0x267F,
             0x2693,
             0x26A1,
             0x26AA...0x26AB,
             0x26BD...0x26BE,
             0x26C4...0x26C5,
             0x26CE,
             0x26D4,
             0x26EA,
             0x26F2...0x26F3,
             0x26F5,
             0x26FA,
             0x26FD,
             0x2705,
             0x270A...0x270B,
             0x2728,
             0x274C,
             0x274E,
             0x2753...0x2755,
             0x2757,
             0x2795...0x2797,
             0x27B0,
             0x27BF,
             0x2B1B...0x2B1C,
             0x2B50,
             0x2B55,
             0x2E80...0xA4CF,
             0xAC00...0xD7A3,
             0xF900...0xFAFF,
             0xFE10...0xFE19,
             0xFE30...0xFE6F,
             0xFF00...0xFF60,
             0xFFE0...0xFFE6,
             0x1F300...0x1F64F,
             0x1F680...0x1F6FF,
             0x1F900...0x1F9FF,
             0x1FA70...0x1FAFF,
             0x20000...0x3FFFD:
            return 2
        default:
            return 1
        }
    }
}

private struct BoundedTextSelectionModifier: ViewModifier {
    let text: String
    let mode: LargeTextSelectionPolicy.Mode

    func body(content: Content) -> some View {
        switch mode {
        case .liveSelection:
            content.textSelection(.enabled)
        case .copyOnly:
            content.copyOnlyTextSelection(for: text)
        }
    }
}

extension View {
    func boundedTextSelection(
        for text: String,
        mode: LargeTextSelectionPolicy.Mode
    ) -> some View {
        modifier(
            BoundedTextSelectionModifier(
                text: text,
                mode: mode
            )
        )
    }

    func copyOnlyTextSelection(for text: String) -> some View {
        contextMenu {
            Button {
                WorkspaceSurfaceIdentifierClipboardText.copy(text)
            } label: {
                Text(String(localized: "textSelection.copyText", defaultValue: "Copy Text"))
            }
        }
    }
}
