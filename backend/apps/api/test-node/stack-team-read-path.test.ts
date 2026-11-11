// Detector for the class of review F1 at f2d36575 (manaflow-ai/cmux #39995): a read of a shared team's sign-in
// service record that does not feed TeamDO's ticketed grant copy lets a team delete carry a grant older than one
// TeamDO already saw. Every such read goes through cloud-vm-plan.ts readStackTeam; this fails on any other caller.
import { readdirSync, readFileSync } from "node:fs"
import { dirname, join, relative } from "node:path"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"

const src = join(dirname(fileURLToPath(import.meta.url)), "../src")
const files = (dir: string): Array<string> =>
  readdirSync(dir, { withFileTypes: true }).flatMap((e) => (e.isDirectory() ? files(join(dir, e.name)) : e.name.endsWith(".ts") ? [join(dir, e.name)] : []))

describe("a shared team's record is read in one place", () => {
  it("only readStackTeam calls StackServer.getTeam", () => {
    const callers = files(src)
      .filter((f) => !f.endsWith("stack-server.ts"))
      .flatMap((f) => readFileSync(f, "utf8").split("\n").map((line, i) => ({ f: relative(src, f), i: i + 1, line })))
      .filter((l) => /\.getTeam\(/.test(l.line))
      .map((l) => `${l.f}:${l.i}`)
    expect(callers).toHaveLength(1)
    expect(callers[0]).toMatch(/^cloud-vm-plan\.ts:/)
  })
})
