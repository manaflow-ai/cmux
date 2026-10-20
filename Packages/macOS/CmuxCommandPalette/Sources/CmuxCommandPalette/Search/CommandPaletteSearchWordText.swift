import Foundation

func commandPaletteNormalizedSearchWordText(
    characters: [Character],
    segments: [CommandPaletteFuzzyMatcher.WordSegment]
) -> String {
    var words: [String] = []
    words.reserveCapacity(segments.count)

    for segment in segments {
        let wordCharacters = characters[segment.start..<segment.end]
        guard wordCharacters.contains(where: commandPaletteContainsSearchWordScalar) else {
            continue
        }
        words.append(String(wordCharacters))
    }

    return words.joined(separator: " ")
}

private func commandPaletteContainsSearchWordScalar(_ character: Character) -> Bool {
    character.unicodeScalars.contains {
        CharacterSet.alphanumerics.contains($0)
    }
}
