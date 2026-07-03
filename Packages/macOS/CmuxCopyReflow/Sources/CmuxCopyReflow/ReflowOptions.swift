import Foundation

/// Tuning knobs for ``ReflowOptions/reflow(_:)``.
///
/// Defaults are deliberately conservative: the engine prefers leaving text
/// untouched (a wrap left unjoined) over merging lines that were intentionally
/// separate (logs, file lists, value columns). See ``ReflowOptions/default``.
public struct ReflowOptions: Sendable {
    /// Leading glyphs that terminal UIs print as decoration and that should be
    /// stripped from the start of a line (outside fenced code). Order does not
    /// matter; each is matched as a single leading character optionally
    /// followed by one space.
    public var decorationCharacters: Set<Character>

    /// A block of wrapped prose is only reflowed when its widest line is at
    /// least this many columns. Narrow blocks (short lists, menus, columns of
    /// paths) are never width-joined. The continuation-indent signal is not
    /// gated by this.
    public var minWrapWidth: Int

    /// A physical line counts as "full" (i.e. it wrapped) when its visible
    /// length is within this many columns of the widest line observed in the
    /// current paragraph candidate.
    public var widthTolerance: Int

    /// Characters that end a sentence/paragraph. The engine never joins onto a
    /// line that ends with one of these, which keeps complete sentences and
    /// list tails on their own lines.
    public var sentenceTerminators: Set<Character>

    public init(
        decorationCharacters: Set<Character>,
        minWrapWidth: Int,
        widthTolerance: Int,
        sentenceTerminators: Set<Character>
    ) {
        self.decorationCharacters = decorationCharacters
        self.minWrapWidth = minWrapWidth
        self.widthTolerance = widthTolerance
        self.sentenceTerminators = sentenceTerminators
    }

    /// The conservative defaults used for terminal copy reflow.
    public static let `default` = ReflowOptions(
        decorationCharacters: ["●", "◆", "▶", "▸", "■", "□", "◇", "○", "›", "»", "❯", "➜", "✔", "✓", "✗", "✘"],
        minWrapWidth: 40,
        widthTolerance: 4,
        sentenceTerminators: [".", "!", "?", "。", "！", "？"]
    )
}
