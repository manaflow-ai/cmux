/**
 * JSON with comments (`//`, `/* *\/`) and trailing commas, as the editor
 * accepts it. The canonical stored form is plain JSON.
 */
export const stripJsonc = (text: string): string => {
  let out = ""
  let i = 0
  const n = text.length
  while (i < n) {
    const c = text[i]!
    if (c === '"') {
      // Copy a string literal verbatim, honoring escapes.
      let j = i + 1
      while (j < n && text[j] !== '"') j += text[j] === "\\" ? 2 : 1
      out += text.slice(i, j + 1)
      i = j + 1
      continue
    }
    if (c === "/" && text[i + 1] === "/") {
      while (i < n && text[i] !== "\n") i++
      continue
    }
    if (c === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2)
      // Keep newlines so JSON.parse positions still map to lines.
      const body = end < 0 ? text.slice(i) : text.slice(i, end + 2)
      out += body.replace(/[^\n]/g, " ")
      i = end < 0 ? n : end + 2
      continue
    }
    if (c === ",") {
      // Drop a comma followed only by whitespace/comments and a closer.
      let j = i + 1
      for (;;) {
        while (j < n && /\s/.test(text[j]!)) j++
        if (text[j] === "/" && text[j + 1] === "/") {
          while (j < n && text[j] !== "\n") j++
          continue
        }
        if (text[j] === "/" && text[j + 1] === "*") {
          const end = text.indexOf("*/", j + 2)
          j = end < 0 ? n : end + 2
          continue
        }
        break
      }
      if (text[j] === "}" || text[j] === "]") {
        out += " "
        i++
        continue
      }
    }
    out += c
    i++
  }
  return out
}

export const parseJsonc = (text: string): { ok: true; value: unknown } | { ok: false; message: string } => {
  try {
    return { ok: true, value: JSON.parse(stripJsonc(text)) }
  } catch (e) {
    return { ok: false, message: e instanceof Error ? e.message : String(e) }
  }
}
