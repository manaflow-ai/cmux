import AppKit

/// Shared visible-glyph geometry for sidebar pointer and accessibility links.
@MainActor
struct SidebarRowTextLinkLayout {
    let attributedString: NSAttributedString
    let textRectSize: NSSize
    let lineBreakMode: NSLineBreakMode
    let maximumNumberOfLines: Int
    private let storage: NSTextStorage
    private let layoutManager: NSLayoutManager
    private let textContainer: NSTextContainer

    init(
        attributedString: NSAttributedString,
        textRectSize: NSSize,
        lineBreakMode: NSLineBreakMode,
        maximumNumberOfLines: Int
    ) {
        self.attributedString = attributedString
        self.textRectSize = textRectSize
        self.lineBreakMode = lineBreakMode
        self.maximumNumberOfLines = maximumNumberOfLines
        storage = NSTextStorage(attributedString: attributedString)
        layoutManager = NSLayoutManager()
        textContainer = NSTextContainer(size: textRectSize)
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = maximumNumberOfLines
        // Match NSCell.truncatesLastVisibleLine for pointer and AX geometry.
        textContainer.lineBreakMode = lineBreakMode
        layoutManager.addTextContainer(textContainer)
        storage.addLayoutManager(layoutManager)
    }

    func characterIndex(at point: NSPoint) -> Int? {
        layoutManager.ensureLayout(for: textContainer)
        guard layoutManager.usedRect(for: textContainer).contains(point) else { return nil }
        let index = layoutManager.glyphIndex(for: point, in: textContainer)
        guard index < layoutManager.numberOfGlyphs else { return nil }
        let range = NSRange(location: index, length: 1)
        guard layoutManager.boundingRect(forGlyphRange: range, in: textContainer).contains(point),
              !visibleGlyphRanges(in: range).isEmpty else { return nil }
        let characterIndex = layoutManager.characterIndexForGlyph(at: index)
        return characterIndex < attributedString.length ? characterIndex : nil
    }

    func frame(forCharacterRange range: NSRange) -> NSRect {
        layoutManager.ensureLayout(for: textContainer)
        let bounded = NSIntersectionRange(range, NSRange(location: 0, length: attributedString.length))
        guard bounded.length > 0 else { return .zero }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: bounded, actualCharacterRange: nil)
        let containerBounds = NSRect(origin: .zero, size: textContainer.size)
        var frame: NSRect?
        for visibleRange in visibleGlyphRanges(in: glyphRange) {
            let part = layoutManager.boundingRect(forGlyphRange: visibleRange, in: textContainer)
                .intersection(containerBounds)
            guard !part.isEmpty else { continue }
            frame = frame.map { $0.union(part) } ?? part
        }
        return frame ?? .zero
    }

    private func visibleGlyphRanges(in glyphRange: NSRange) -> [NSRange] {
        let containerGlyphRange = layoutManager.glyphRange(for: textContainer)
        let candidateRange = NSIntersectionRange(glyphRange, containerGlyphRange)
        guard candidateRange.length > 0 else { return [] }
        var result: [NSRange] = []
        layoutManager.enumerateLineFragments(forGlyphRange: candidateRange) {
            _, _, _, lineGlyphRange, _ in
            let lineCandidate = NSIntersectionRange(candidateRange, lineGlyphRange)
            guard lineCandidate.length > 0 else { return }
            let truncatedRange = layoutManager.truncatedGlyphRange(
                inLineFragmentForGlyphAt: lineGlyphRange.location
            )
            guard truncatedRange.location != NSNotFound, truncatedRange.length > 0 else {
                result.append(lineCandidate)
                return
            }
            let hiddenRange = NSIntersectionRange(lineCandidate, truncatedRange)
            guard hiddenRange.length > 0 else {
                result.append(lineCandidate)
                return
            }
            if lineCandidate.location < hiddenRange.location {
                result.append(NSRange(
                    location: lineCandidate.location,
                    length: hiddenRange.location - lineCandidate.location
                ))
            }
            let hiddenEnd = NSMaxRange(hiddenRange)
            let lineEnd = NSMaxRange(lineCandidate)
            if hiddenEnd < lineEnd {
                result.append(NSRange(location: hiddenEnd, length: lineEnd - hiddenEnd))
            }
        }
        return result
    }
}
