import SwiftUI

enum LargeTextSelectionPolicy {
    enum Mode: Equatable {
        case liveSelection
        case copyOnly
    }

    static let defaultMaximumLiveSelectionLineFragments = 2_000
    static let defaultCharactersPerWrappedLine = 100

    nonisolated static func mode(
        for text: String,
        charactersPerWrappedLine: Int = defaultCharactersPerWrappedLine,
        maximumLineFragments: Int = defaultMaximumLiveSelectionLineFragments
    ) -> Mode {
        guard charactersPerWrappedLine > 0, maximumLineFragments > 0 else {
            return .copyOnly
        }

        var lineFragments = 0
        var currentLineCharacters = 0
        var sawAnyCharacter = false
        var previousCharacterWasNewline = false

        func appendLineFragment() -> Bool {
            currentLineCharacters = 0
            lineFragments += 1
            return lineFragments <= maximumLineFragments
        }

        for scalar in text.unicodeScalars {
            sawAnyCharacter = true
            if scalar.value == 10 {
                if currentLineCharacters > 0 || previousCharacterWasNewline || lineFragments == 0 {
                    guard appendLineFragment() else { return .copyOnly }
                }
                previousCharacterWasNewline = true
            } else {
                previousCharacterWasNewline = false
                currentLineCharacters += 1
                if currentLineCharacters >= charactersPerWrappedLine {
                    guard appendLineFragment() else { return .copyOnly }
                }
            }
        }

        if currentLineCharacters > 0 || !sawAnyCharacter || previousCharacterWasNewline {
            guard appendLineFragment() else { return .copyOnly }
        }
        return .liveSelection
    }
}

private struct BoundedTextSelectionModifier: ViewModifier {
    let text: String
    let charactersPerWrappedLine: Int
    let maximumLineFragments: Int

    func body(content: Content) -> some View {
        switch LargeTextSelectionPolicy.mode(
            for: text,
            charactersPerWrappedLine: charactersPerWrappedLine,
            maximumLineFragments: maximumLineFragments
        ) {
        case .liveSelection:
            content.textSelection(.enabled)
        case .copyOnly:
            content.contextMenu {
                Button {
                    WorkspaceSurfaceIdentifierClipboardText.copy(text)
                } label: {
                    Text(String(localized: "textSelection.copyText", defaultValue: "Copy Text"))
                }
            }
        }
    }
}

extension View {
    func boundedTextSelection(
        for text: String,
        charactersPerWrappedLine: Int = LargeTextSelectionPolicy.defaultCharactersPerWrappedLine,
        maximumLineFragments: Int = LargeTextSelectionPolicy.defaultMaximumLiveSelectionLineFragments
    ) -> some View {
        modifier(
            BoundedTextSelectionModifier(
                text: text,
                charactersPerWrappedLine: charactersPerWrappedLine,
                maximumLineFragments: maximumLineFragments
            )
        )
    }
}
