/**
 * Accent- and case-insensitive matching for the `home.search` highlight. The MySQL projection
 * matches with the utf8mb4_0900_ai_ci collation, which folds case and accents, so a row found by
 * `cafe` may contain only `café`. The highlight has to fold the same way, or that hit has no range.
 *
 * Folding can change length (NFD splits `é` into `e` and a combining mark, `ß` becomes `ss`, `ﬁ`
 * becomes `fi`), so the text is folded one grapheme at a time and a match in the folded text maps
 * back to whole graphemes of the original. Offsets are code points, as in the hit's snippet ranges.
 */

/**
 * Combining marks the collation ignores at the base-letter level: Latin, Greek and Cyrillic accents
 * (the ones NFKD splits off), Hebrew points and Arabic harakat. Kana voicing marks are kept, so `か`
 * still does not match `が`, and Indic vowel signs are kept because they are letters there.
 */
const DIACRITICS =
  /[\u0300-\u036f\u0591-\u05bd\u05bf\u05c1\u05c2\u05c4\u05c5\u05c7\u0610-\u061a\u064b-\u065f\u0670\u06d6-\u06dc\u06df-\u06e4\u06e7\u06e8\u06ea-\u06ed\u1ab0-\u1aff\u1dc0-\u1dff\u20d0-\u20ff\ufe20-\ufe2f]/gu
/**
 * Letters with no Unicode decomposition that the collation still weighs as a base letter (or two)
 * plus an accent-level difference: expansions, the stroke and bar letters, and final sigma.
 * Best effort: a letter missing here only loses its highlight, never the hit.
 */
const LETTERS: Readonly<Record<string, string>> = {
  "ß": "ss", "æ": "ae", "œ": "oe", "ĳ": "ij", "ø": "o", "đ": "d", "ð": "d", "ł": "l", "ħ": "h", "ŧ": "t",
  "ƀ": "b", "ǥ": "g", "ɨ": "i", "ʉ": "u", "ɍ": "r", "ɉ": "j", "ƶ": "z", "ς": "σ"
}
const LETTER = new RegExp(`[${Object.keys(LETTERS).join("")}]`, "gu")

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

/** One grapheme folded; a single ASCII character (most text) skips normalization. */
const foldGrapheme = (g: string) => (g.length === 1 && g.charCodeAt(0) < 0x80 ? g.toLowerCase() : foldText(g))

const foldGraphemes = (s: string) => Array.from(graphemes.segment(s), ({ segment }) => foldGrapheme(segment)).join("")

/** The number of entries of the ascending `xs` that are at most `v`. */
const countAtMost = (xs: ReadonlyArray<number>, v: number) => {
  let lo = 0
  let hi = xs.length
  while (lo < hi) {
    const mid = (lo + hi) >> 1
    if (xs[mid]! <= v) lo = mid + 1
    else hi = mid
  }
  return lo
}

/**
 * The first match of `query` in `text` under folding, as a code-point range of `text` covering
 * whole graphemes (a match that starts or ends inside one grapheme's fold, such as `s` in `ß`,
 * covers that grapheme). Null when the query folds to nothing or does not occur. One pass folds the
 * text and records where each grapheme starts, one indexOf finds the match, and two binary searches
 * map its ends back.
 */
export const foldedMatch = (text: string, query: string): { readonly start: number; readonly length: number } | null => {
  const needle = foldGraphemes(query)
  if (needle.length === 0) return null
  const parts: Array<string> = []
  // Per grapheme, plus one past the end: where it starts in the folded text (UTF-16) and in `text` (code points).
  const foldAt: Array<number> = []
  const codeAt: Array<number> = []
  let folded = 0
  let code = 0
  for (const { segment } of graphemes.segment(text)) {
    const f = foldGrapheme(segment)
    foldAt.push(folded)
    codeAt.push(code)
    parts.push(f)
    folded += f.length
    code += segment.length === 1 ? 1 : [...segment].length
  }
  foldAt.push(folded)
  codeAt.push(code)
  const at = parts.join("").indexOf(needle)
  if (at < 0) return null
  // First grapheme: the last one whose fold starts at or before `at` (graphemes folding to nothing
  // share the next one's start, so they are passed over). End: the first grapheme start at or past the match end.
  const first = countAtMost(foldAt, at) - 1
  const last = countAtMost(foldAt, at + needle.length - 1)
  return { start: codeAt[first]!, length: codeAt[last]! - codeAt[first]! }
}
