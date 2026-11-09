import { appendFileSync, readFileSync, statSync, utimesSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"
import { writeChiefVmSource } from "../scripts/gen-chief-vm-source.ts"

/**
 * The generator runs as wrangler's build command, and its output is in wrangler's watch dir (wrangler.jsonc): a write
 * of the same bytes would start another build, and so on for as long as `wrangler dev` runs.
 */
describe("gen-chief-vm-source", () => {
  const out = fileURLToPath(new URL("../src/chief-brain-cc/chief-vm-source.ts", import.meta.url))

  it("leaves a current file untouched and rewrites a stale one", () => {
    writeChiefVmSource()
    const current = readFileSync(out, "utf8")
    const old = new Date("2020-01-01T00:00:00Z")
    utimesSync(out, old, old)
    writeChiefVmSource()
    expect(statSync(out).mtimeMs).toBe(old.getTime())

    appendFileSync(out, "// stale\n")
    writeChiefVmSource()
    expect(readFileSync(out, "utf8")).toBe(current)
  })
})
