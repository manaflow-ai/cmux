/**
 * Accent- and case-insensitive matching for the `home.search` highlight. The MySQL projection
 * matches with the utf8mb4_0900_ai_ci collation, which folds case and accents, so a row found by
 * `cafe` may contain only `café`. The highlight has to fold the same way, or that hit has no range.
 *
 * Folding can change length (NFD splits `é` into `e` and a combining mark, `ß` becomes `ss`, `ﬁ`
 * becomes `fi`), so the text is folded one grapheme at a time and a match in the folded text maps
 * back to whole graphemes of the original. Offsets are code points, as in the hit's snippet ranges.
 */

/** Combining diacritical marks (the accents NFKD splits off Latin, Greek and Cyrillic letters). */
const DIACRITICS = /[̀-ͯ᪰-᫿᷀-᷿⃐-⃿︠-︯]/gu
/** Letters the collation treats as a base letter (or two) that have no Unicode decomposition. */
const LETTERS: Readonly<Record<string, string>> = { "ß": "ss", "æ": "ae", "œ": "oe", "ø": "o", "đ": "d", "ł": "l", "ς": "σ" }
const LETTER = /[ßæœøđłς]/gu

/**
 * One grapheme (or any text) folded: compatibility forms decomposed (ligatures, full-width), accents
 * dropped, lower case, the LETTERS table, then NFC. NFC recomposes what NFKD split but did not drop,
 * so Hangul syllables and kana with voiced marks fold to themselves and CJK matches as before.
 */
export const foldText = (s: string): string =>
  s
    .normalize("NFKD")
    .replace(DIACRITICS, "")
    .toLowerCase()
    .replace(LETTER, (c) => LETTERS[c] ?? c)
    .normalize("NFC")

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

const foldGraphemes = (s: string) => Array.from(graphemes.segment(s), ({ segment }) => foldText(segment)).join("")

/**
 * The first match of `query` in `text` under folding, as a code-point range of `text` covering
 * whole graphemes (a match that starts or ends inside one grapheme's fold, such as `s` in `ß`,
 * covers that grapheme). Null when the query folds to nothing or does not occur.
 */
export const foldedMatch = (text: string, query: string): { readonly start: number; readonly length: number } | null => {
  const needle = foldGraphemes(query)
  if (needle.length === 0) return null
  let folded = ""
  // Per grapheme so far: where its fold starts in `folded` (UTF-16) and where it starts in `text` (code points).
  const foldAt: Array<number> = []
  const codeAt: Array<number> = []
  let code = 0
  for (const { segment } of graphemes.segment(text)) {
    const before = folded.length
    foldAt.push(before)
    codeAt.push(code)
    folded += foldText(segment)
    code += [...segment].length
    // A match ending in this grapheme's fold starts after `before - needle.length`; earlier ones were checked.
    const at = folded.indexOf(needle, Math.max(0, before - needle.length + 1))
    if (at < 0) continue
    // The match ends in this grapheme; it starts in the last grapheme whose fold starts at or before
    // `at` (that skips graphemes folding to nothing, which share the next one's start).
    let first = foldAt.length - 1
    while (first > 0 && foldAt[first]! > at) first--
    return { start: codeAt[first]!, length: code - codeAt[first]! }
  }
  return null
}
