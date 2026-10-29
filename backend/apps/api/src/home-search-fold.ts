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

/** Whether one code point is a combining mark the fold drops (an accent, not a kana voicing mark). */
export const isDroppedMark = (ch: string): boolean => /^\p{M}$/u.test(ch) && foldText(ch) === ""

const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" })

/**
 * Folds of graphemes seen before: text reuses a small alphabet, so most graphemes skip the two
 * normalizations. Bounded; cleared when full, so its memory never grows past FOLD_CACHE_MAX entries.
 */
const FOLD_CACHE_MAX = 8192
const foldCache = new Map<string, string>()

/** One grapheme folded; a single ASCII character (most text) skips normalization. */
const foldGrapheme = (g: string) => {
  if (g.length === 1 && g.charCodeAt(0) < 0x80) return g.toLowerCase()
  let f = foldCache.get(g)
  if (f === undefined) {
    if (foldCache.size >= FOLD_CACHE_MAX) foldCache.clear()
    f = foldText(g)
    foldCache.set(g, f)
  }
  return f
}

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
 * ASCII runs. The last ASCII character before non-ASCII text goes with that text, since it can be
 * the base of a grapheme (`e` and a combining accent, a digit and a keycap mark).
 */
const ASCII_RUN = /[\x00-\x7f]+/g
const CHECK_EVERY = 1024

/**
 * The first match of `query` in `text` under folding, as a code-point range of `text` covering
 * whole graphemes (a match that starts or ends inside one grapheme's fold, such as `s` in `ß`,
 * covers that grapheme). Null when the query folds to nothing or does not occur.
 *
 * Cost is linear in the text: ASCII runs fold with one toLowerCase each and map back one to one
 * (a "linear" piece); only non-ASCII stretches go through Intl.Segmenter, one piece per grapheme.
 * Folding stops shortly after the first match, and binary searches over the pieces map its ends back.
 */
export const foldedMatch = (text: string, query: string): { readonly start: number; readonly length: number } | null => {
  const needle = foldGraphemes(query)
  if (needle.length === 0) return null
  // Per piece, plus one past the end: where it starts in the folded text (UTF-16) and in `text` (code points).
  const foldAt: Array<number> = []
  const codeAt: Array<number> = []
  const linear: Array<boolean> = []
  let folded = ""
  let code = 0
  // Folding stops at the first match: it is looked for every CHECK_EVERY folded units, from just
  // before the part not yet searched, and once more at the end.
  let searched = 0
  let at = -1
  const look = () => {
    at = folded.indexOf(needle, Math.max(0, searched - needle.length + 1))
    searched = folded.length
    return at >= 0
  }
  const piece = (f: string, codePoints: number, isLinear: boolean) => {
    foldAt.push(folded.length)
    codeAt.push(code)
    linear.push(isLinear)
    folded += f
    code += codePoints
    return folded.length - searched >= CHECK_EVERY && look()
  }
  const nonAscii = (from: number, to: number) => {
    if (to <= from) return false
    for (const { segment } of graphemes.segment(text.slice(from, to))) if (piece(foldGrapheme(segment), segment.length === 1 ? 1 : [...segment].length, false)) return true
    return false
  }
  const scan = () => {
    let next = 0
    for (const m of text.matchAll(ASCII_RUN)) {
      const start = m.index ?? 0
      // Keep the run's last character for the non-ASCII text after it, if any.
      const end = start + m[0].length - (start + m[0].length < text.length ? 1 : 0)
      if (nonAscii(next, start)) return
      if (end > start && piece(text.slice(start, end).toLowerCase(), end - start, true)) return
      next = end
    }
    if (!nonAscii(next, text.length)) look()
  }
  scan()
  foldAt.push(folded.length)
  codeAt.push(code)
  if (at < 0) return null
  const last = at + needle.length - 1
  // Start: the last piece whose fold starts at or before `at` (graphemes folding to nothing share
  // the next piece's start, so they are passed over); a linear piece maps one to one.
  const p = countAtMost(foldAt, at) - 1
  const startCode = linear[p] ? codeAt[p]! + (at - foldAt[p]!) : codeAt[p]!
  // End: within the piece holding the match's last folded unit, or that grapheme's end.
  const q = countAtMost(foldAt, last) - 1
  const endCode = linear[q] ? codeAt[q]! + (last + 1 - foldAt[q]!) : codeAt[q + 1]!
  return { start: startCode, length: endCode - startCode }
}
