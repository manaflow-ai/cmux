import { spawnSync } from "node:child_process"
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { ACPMUX_EXIT_NO_WORK_USER, acpmuxKeyedStartCommand, acpmuxPersonHoldsCommand, acpmuxPrepareCommand, layoutSelector } from "../src/cloud-acpmux-guest.ts"

const ok = "#!/bin/sh\nexit 0\n"
const report = '; printf %s:%s:%s "$CMUX_TUI_USER" "$CMUX_TUI_HOME" "$CMUX_TUI_BIN"'

/** Runs `snippet` in /bin/sh with stub binaries first on PATH. */
const run = (snippet: string, stubs: Record<string, string>) => {
  const root = mkdtempSync(join(tmpdir(), "cloud-acpmux-layout-"))
  const bin = join(root, "bin")
  mkdirSync(bin)
  try {
    for (const [name, body] of Object.entries(stubs)) {
      writeFileSync(join(bin, name), body)
      chmodSync(join(bin, name), 0o755)
    }
    return spawnSync("/bin/sh", ["-c", snippet], { encoding: "utf8", env: { ...process.env, PATH: [bin, "/usr/bin", "/bin"].join(":") } })
  } finally { rmSync(root, { recursive: true, force: true }) }
}

describe("the Worker's agent layout selector fails closed", () => {
  it("never selects root, in any command", () => {
    for (const command of [layoutSelector(), acpmuxPrepareCommand(), acpmuxKeyedStartCommand(), acpmuxPersonHoldsCommand()]) {
      expect(command).not.toContain("CMUX_TUI_USER=root")
      expect(command).not.toContain("/root")
    }
  })

  it("runs the agent as the work user when it is usable", () => {
    const out = run(`${layoutSelector()}${report}`, { id: ok, setpriv: ok, sudo: ok })
    expect(out.status, out.stderr).toBe(0)
    expect(out.stdout).toBe("cmux:/home/cmux:/home/cmux/.cmux/bin/cmux-tui")
  })

  it.each([
    ["a missing work user", { id: "#!/bin/sh\nexit 1\n", setpriv: ok }],
    ["a work home it cannot write", { id: ok, setpriv: '#!/bin/sh\ncase "$*" in *test*) exit 1;; esac\nexit 0\n', sudo: ok }],
    ["no passwordless sudo", { id: ok, setpriv: '#!/bin/sh\ncase "$*" in *sudo*) exit 1;; esac\nexit 0\n', sudo: ok }],
  ])("%s fails with a clear error and its own exit status", (_name, stubs) => {
    const out = run(`${layoutSelector()}${report}`, stubs)
    expect(out.status).toBe(ACPMUX_EXIT_NO_WORK_USER)
    expect(out.stdout).toBe("")
    expect(out.stderr).toContain("agents never run as root")
  })
})
