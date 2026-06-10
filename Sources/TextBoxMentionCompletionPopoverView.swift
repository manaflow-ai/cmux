import AppKit
import Carbon.HIToolbox
import SwiftUI
import UniformTypeIdentifiers
import os


// MARK: - Mention Completion Popover
struct TextBoxMentionCompletionPopoverView: View {
    let suggestions: [TextBoxMentionSuggestion]
    let selectionIndex: Int
    let searchTerm: String
    let isLoading: Bool
    let onSelect: (TextBoxMentionSuggestion) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if suggestions.isEmpty, isLoading {
                        HStack {
                            Spacer(minLength: 0)
                            ProgressView()
                                .controlSize(.small)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: 28, alignment: .center)
                    } else {
                        ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                            Button {
                                onSelect(suggestion)
                            } label: {
                                Text(Self.highlightedTitle(suggestion.title, query: searchTerm))
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .padding(.horizontal, 8)
                                    .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                                    .background {
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(index == selectionIndex ? Color.accentColor.opacity(0.24) : Color.clear)
                                    }
                            }
                            .buttonStyle(.plain)
                            .id(index)
                        }
                    }
                }
                .padding(4)
            }
            .onChange(of: selectionIndex) { _, newValue in
                proxy.scrollTo(newValue, anchor: nil)
            }
        }
        .frame(width: 360)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private static func highlightedTitle(_ title: String, query: String) -> AttributedString {
        var attributed = AttributedString(title)
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return attributed }
        let ranges = subsequenceMatchRanges(query: trimmedQuery, in: title)
        guard !ranges.isEmpty else { return attributed }
        for range in ranges {
            guard let attrLower = AttributedString.Index(range.lowerBound, within: attributed),
                  let attrUpper = AttributedString.Index(range.upperBound, within: attributed) else {
                continue
            }
            attributed[attrLower..<attrUpper].foregroundColor = .accentColor
            attributed[attrLower..<attrUpper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }

    private static func subsequenceMatchRanges(query: String, in text: String) -> [Range<String.Index>] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var queryIndex = query.startIndex
        var textIndex = text.startIndex

        while queryIndex < query.endIndex, textIndex < text.endIndex {
            let nextTextIndex = text.index(after: textIndex)
            let nextQueryIndex = query.index(after: queryIndex)
            let textCharacter = String(text[textIndex..<nextTextIndex])
            let queryCharacter = String(query[queryIndex..<nextQueryIndex])
            if textCharacter.compare(
                queryCharacter,
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: nil
            ) == .orderedSame {
                ranges.append(textIndex..<nextTextIndex)
                queryIndex = nextQueryIndex
            }
            textIndex = nextTextIndex
        }

        return queryIndex == query.endIndex ? ranges : []
    }
}

final class TextBoxMentionCompletionPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

