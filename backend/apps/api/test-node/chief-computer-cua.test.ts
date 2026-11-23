import { spawnSync } from "node:child_process"
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterEach, describe, expect, it } from "vitest"
import { CUA_FALLBACK, DESKTOP_PRELUDE } from "../src/chief-brain-cc/sandbox-computer-setup.ts"
import { inputCommand } from "../src/chief-brain-cc/sandbox-computer.ts"

/**
 * The Chief's computer input under bash with a stand-in cua-driver and xdotool on PATH (sandbox-computer.ts cuaOr):
 * xdotool runs only when cua-driver ran nothing (missing, or an unknown tool or argument); any other cua-driver error
 * fails the verb without repeating the action.
 */
const dirs: Array<string> = []
afterEach(() => {
  for (const d of dirs.splice(0)) rmSync(d, { recursive: true, force: true })
})

const run = (cuaDriver: string | null) => {
  const dir = mkdtempSync(join(tmpdir(), "chief-cua-"))
  dirs.push(dir)
  const log = join(dir, "log")
  writeFileSync(log, "")
  const tool = (name: string, body: string) => {
    writeFileSync(join(dir, name), `#!/bin/bash\n${body}\n`)
    chmodSync(join(dir, name), 0o755)
  }
  tool("xdotool", `echo "xdotool $*" >> ${log}`)
  if (cuaDriver !== null) tool("cua-driver", `echo "cua-driver $*" >> ${log}\n${cuaDriver}`)
  const input = inputCommand("type", { text: "hello" })
  if (typeof input === "string") throw new Error(input)
  // Only the prelude's `cua` function (the desktop start needs a real X server), then the verb's own line.
  const cua = DESKTOP_PRELUDE.slice(DESKTOP_PRELUDE.indexOf("cua() {"))
  const verb = input.command.slice(DESKTOP_PRELUDE.length)
  const r = spawnSync("/bin/bash", ["-c", `${cua}\n${verb}`], { env: { PATH: `${dir}:/usr/bin:/bin`, ...input.env }, encoding: "utf8" })
  return { exit: r.status, stderr: r.stderr, calls: readFileSync(log, "utf8").trim().split("\n").filter(Boolean) }
}

describe("cuaOr: the xdotool fallback runs only when cua-driver ran nothing", () => {
  it("uses cua-driver alone when it succeeds", () => {
    const r = run(`echo '{"content":[{"type":"text","text":"ok"}]}'`)
    expect(r.exit).toBe(0)
    expect(r.calls).toEqual([expect.stringMatching(/^cua-driver call type_text /)])
  })
  it("falls back when cua-driver is missing", () => {
    const r = run(null)
    expect(r.exit).toBe(0)
    expect(r.calls).toEqual(["xdotool type --delay 20 -- hello"])
  })
  it("falls back when cua-driver does not know the tool or an argument", () => {
    for (const answer of [`echo 'error: unknown tool: type_text'; exit 2`, `echo '{"isError": true, "content":[{"type":"text","text":"Unknown argument: scope"}]}'`]) {
      const r = run(answer)
      expect(r.exit, answer).toBe(0)
      expect(r.calls.at(-1), answer).toBe("xdotool type --delay 20 -- hello")
    }
  })
  it("fails without repeating the action when cua-driver errs after it may have run", () => {
    for (const answer of [`echo 'typing interrupted after 3 characters'; exit 1`, `echo '{"isError": true, "content":[{"type":"text","text":"window lost focus"}]}'`]) {
      const r = run(answer)
      expect(r.exit, answer).not.toBe(0)
      expect(r.exit).not.toBe(CUA_FALLBACK)
      expect(r.calls.some((c) => c.startsWith("xdotool")), answer).toBe(false)
      expect(r.stderr).toContain("cua-driver type_text")
    }
  })
})
