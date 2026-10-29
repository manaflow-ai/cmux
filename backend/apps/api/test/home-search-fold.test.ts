import { describe, expect, it } from "vitest"
import { encodeCursor, hitOf } from "../src/home-search.ts"
import { foldedMatch, foldText } from "../src/home-search-fold.ts"

/**
 * The home.search highlight folds case and accents the way the MySQL collation matched the row, and
 * maps the range back to code points of the original text when folding changes length.
 */
const row = (body: string) => ({ conversation_id: "conv_A", title: "T", seq: "7", message_id: "msg_1", author_id: "user_a", created_at: "2026-10-03T00:00:00.000Z", body })
/** The highlighted text of the first range, read by code points as the client does. */
const shown = (h: ReturnType<typeof hitOf>) => (h.ranges[0] ? [...h.snippet].slice(h.ranges[0].start, h.ranges[0].start + h.ranges[0].length).join("") : null)

describe("home.search highlight under folding", () => {
  it("highlights café for the query cafe", () => {
    const h = hitOf(row("Meet at the café at 9"), "cafe")
    expect(h.ranges).toEqual([{ start: 12, length: 4 }])
    expect(shown(h)).toBe("café")
  })

  it("highlights cafe for the query CAFÉ", () => {
    const h = hitOf(row("a cafe here"), "CAFÉ")
    expect(h.ranges).toEqual([{ start: 2, length: 4 }])
    expect(shown(h)).toBe("cafe")
  })

  it("lands offsets right after accented letters, ß, a ligature and an emoji", () => {
    const body = "Résumé für Straße: ﬁnal 👍 café notes"
    expect(hitOf(row(body), "cafe").ranges).toEqual([{ start: 26, length: 4 }])
    expect(shown(hitOf(row(body), "cafe"))).toBe("café")
    expect(hitOf(row(body), "STRASSE").ranges).toEqual([{ start: 11, length: 6 }])
    expect(shown(hitOf(row(body), "final"))).toBe("ﬁnal")
    expect(shown(hitOf(row(body), "resume"))).toBe("Résumé")
    // Part of one grapheme's fold (`s` of `ss`) covers that whole grapheme.
    expect(foldedMatch("aßb", "s")).toEqual({ start: 1, length: 1 })
  })

  it("covers combining marks in the body and in the query", () => {
    const decomposed = "café au lait"
    expect(hitOf(row(decomposed), "café").ranges).toEqual([{ start: 0, length: 5 }])
    expect(hitOf(row(decomposed), "cafe").ranges).toEqual([{ start: 0, length: 5 }])
    expect(hitOf(row(`le ${decomposed}`), "lait").ranges).toEqual([{ start: 12, length: 4 }])
    expect(hitOf(row("un café"), "café").ranges).toEqual([{ start: 3, length: 4 }])
    // A query of only a combining mark folds to nothing and keeps the plain match.
    expect(hitOf(row(decomposed), "́").ranges).toEqual([{ start: 4, length: 1 }])
  })

  it("matches CJK as before", () => {
    expect(hitOf(row("明日の計画を確認します"), "計画").ranges).toEqual([{ start: 3, length: 2 }])
    expect(hitOf(row("한국어 검색 결과"), "검색").ranges).toEqual([{ start: 4, length: 2 }])
    // Voiced kana stay distinct: か does not highlight が, and が is found where it is.
    expect(hitOf(row("がかみ"), "か").ranges).toEqual([{ start: 1, length: 1 }])
    expect(hitOf(row("かがみ"), "が").ranges).toEqual([{ start: 1, length: 1 }])
    expect(foldText("한국어 計画 がぎ")).toBe("한국어 計画 がぎ")
    // A decomposed が keeps its voicing mark out of a plain match for か, as before.
    expect(hitOf(row("か\u3099み"), "か").ranges).toEqual([{ start: 0, length: 1 }])
  })

  it("prefers the plain match, as Postgres ILIKE matched it, and folds only without one", () => {
    expect(hitOf(row("café or cafe"), "cafe").ranges).toEqual([{ start: 8, length: 4 }])
    expect(hitOf(row("café or cafe"), "café").ranges).toEqual([{ start: 0, length: 4 }])
  })

  it("folds stroke letters and eth as the collation does", () => {
    expect(shown(hitOf(row("Vel ðu Øresund Łódź Ħamrun"), "lodz"))).toBe("Łódź")
    expect(shown(hitOf(row("Vel ðu Øresund Łódź Ħamrun"), "hamrun"))).toBe("Ħamrun")
    expect(shown(hitOf(row("Vel ðu Øresund Łódź Ħamrun"), "du oresund"))).toBe("ðu Øresund")
  })

  it("drops Arabic harakat and Hebrew points, as the collation does", () => {
    expect(shown(hitOf(row("قرأت كِتاب اليوم"), "كتاب"))).toBe("كِتاب")
    expect(shown(hitOf(row("זה שָׁלוֹם לך"), "שלום"))).toBe("שָׁלוֹם")
  })

  it("finds a folded match late in a long body", () => {
    const body = `${"plain words ".repeat(5000)}Ünïcödé`
    const h = hitOf(row(body), "unicode")
    expect(shown(h)).toBe("Ünïcödé")
    expect(h.snippet.endsWith("Ünïcödé")).toBe(true)
  })

  it("maps folded matches inside and across ASCII runs", () => {
    // An accented query against an ASCII body, at the start, the middle and the end.
    expect(foldedMatch("cafe", "café")).toEqual({ start: 0, length: 4 })
    expect(foldedMatch("le cafe noir", "CAFÉ")).toEqual({ start: 3, length: 4 })
    expect(foldedMatch("noir cafe", "café")).toEqual({ start: 5, length: 4 })
    // Across a run and a grapheme on both sides, with an emoji before it.
    expect(foldedMatch("👍 xcafé ok", "cafe ok")).toEqual({ start: 3, length: 7 })
    expect(foldedMatch("éa", "ea")).toEqual({ start: 0, length: 2 })
    // A keycap: the digit belongs to the grapheme after it.
    expect(foldedMatch("dial 1\ufe0f\u20e3 now", "1")).toEqual({ start: 5, length: 3 })
    expect(foldedMatch("a\u0301", "a")).toEqual({ start: 0, length: 2 })
  })

  it("finds the first folded match across the points where folding checks and stops", () => {
    // Folding checks every 1024 folded units; these matches straddle or follow those points.
    for (const n of [509, 510, 511, 512, 1022, 1023, 2000]) {
      const body = `${"éa".repeat(n)}éb${"éa".repeat(600)}éb`
      expect(foldedMatch(body, "aeb")).toEqual({ start: 2 * n - 1, length: 3 })
    }
    expect(foldedMatch(`${"x".repeat(5000)}é`, "xe")).toEqual({ start: 4999, length: 2 })
    expect(foldedMatch(`${"x".repeat(5000)}é`, "xé")).toEqual({ start: 4999, length: 2 })
    expect(foldedMatch(`${"é".repeat(5000)}`, "eex")).toBeNull()
  })

  it("returns no range when nothing matches, with the snippet unchanged", () => {
    const h = hitOf(row("plan B"), "zzz")
    expect(h.ranges).toEqual([])
    expect(h.snippet).toBe("plan B")
  })

  it("maps the range into a cut snippet", () => {
    const body = `${"x ".repeat(100)}Ünïcödé café${" y".repeat(100)}`
    const h = hitOf(row(body), "unicode cafe")
    expect(h.snippet.startsWith("…")).toBe(true)
    expect(shown(h)).toBe("Ünïcödé café")
  })

  it("keeps ASCII hits and the paging cursor as before", () => {
    const h = hitOf(row("after join: plan B"), "plan")
    expect(h).toMatchObject({ snippet: "after join: plan B", ranges: [{ start: 12, length: 4 }], seq: 7, created_at: "2026-10-03T00:00:00.000Z" })
    expect(JSON.parse(Buffer.from(encodeCursor(h), "base64url").toString("utf8"))).toEqual(["2026-10-03T00:00:00.000Z", "conv_A", 7])
  })
})
