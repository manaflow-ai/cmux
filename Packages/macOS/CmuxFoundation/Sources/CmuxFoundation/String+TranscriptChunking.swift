import Foundation

/// Paragraph/whitespace-aware chunking used by the session transcript preview to
/// split very long turns into bounded display rows. Pure `String` in/out, with no
/// dependency on the transcript model, so it lives as a `String` extension here
/// alongside the other shared `String+*` helpers.
extension String {
    /// The maximum number of characters in a single transcript chunk before the
    /// text is split on a paragraph (newline) or whitespace boundary.
    private static let transcriptChunkCharacterLimit = 5_000

    /// Splits this string into display chunks no longer than
    /// `transcriptChunkCharacterLimit` characters, breaking on the nearest
    /// preceding newline (else whitespace) inside the final quarter of each chunk
    /// so paragraphs and words stay intact. Each chunk is trimmed of leading and
    /// trailing whitespace, and empty chunks are dropped. A string already within
    /// the limit is returned unchanged as a single chunk.
    public func transcriptChunks() -> [String] {
        guard count > Self.transcriptChunkCharacterLimit else {
            return [self]
        }
        var output: [String] = []
        var start = startIndex
        while start < endIndex {
            let rawEnd = index(
                start,
                offsetBy: Self.transcriptChunkCharacterLimit,
                limitedBy: endIndex
            ) ?? endIndex
            let end = preferredTranscriptBreak(from: start, rawEnd: rawEnd)
            output.append(String(self[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines))
            start = end
            while start < endIndex, self[start].isWhitespace {
                start = index(after: start)
            }
        }
        return output.filter { !$0.isEmpty }
    }

    /// Returns the index at which a chunk spanning `start..<rawEnd` should break:
    /// the position after the last newline in the chunk's final quarter, else
    /// after the last whitespace there, else `rawEnd`. A `rawEnd` at the string's
    /// end always returns `endIndex`.
    private func preferredTranscriptBreak(
        from start: String.Index,
        rawEnd: String.Index
    ) -> String.Index {
        guard rawEnd < endIndex else {
            return endIndex
        }
        let searchStart = index(
            rawEnd,
            offsetBy: -min(Self.transcriptChunkCharacterLimit / 4, distance(from: start, to: rawEnd))
        )
        if let newline = self[searchStart..<rawEnd].lastIndex(of: "\n") {
            return index(after: newline)
        }
        if let space = self[searchStart..<rawEnd].lastIndex(where: { $0.isWhitespace }) {
            return index(after: space)
        }
        return rawEnd
    }
}
