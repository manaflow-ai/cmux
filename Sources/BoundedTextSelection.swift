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
        var currentLineBytes = 0
        var sawAnyByte = false
        var previousByteWasNewline = false

        func appendLineFragment() -> Bool {
            currentLineBytes = 0
            lineFragments += 1
            return lineFragments <= maximumLineFragments
        }

        for byte in text.utf8 {
            sawAnyByte = true
            if byte == 10 {
                if currentLineBytes > 0 || previousByteWasNewline || lineFragments == 0 {
                    guard appendLineFragment() else { return .copyOnly }
                }
                previousByteWasNewline = true
            } else {
                previousByteWasNewline = false
                currentLineBytes += 1
                if currentLineBytes >= charactersPerWrappedLine {
                    guard appendLineFragment() else { return .copyOnly }
                }
            }
        }

        if currentLineBytes > 0 || !sawAnyByte || previousByteWasNewline {
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
