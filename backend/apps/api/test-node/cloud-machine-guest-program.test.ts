// The fs routes' guest program (src/cloud-machine-guest.ts FS_PROGRAM), run with the local python3 on a
// temporary tree. shutil.rmtree and os.unlink are replaced by prints first, so no run can delete anything: the
// test reads which path each would have removed.
import { spawnSync } from "node:child_process"
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterAll, describe, expect, it } from "vitest"
import { FS_PROGRAM } from "../src/cloud-machine-guest.ts"

const python = spawnSync("python3", ["--version"]).status === 0
const DRY = `import os,shutil
shutil.rmtree=lambda p,*a,**k:print("rmtree",p)
os.unlink=lambda p,*a,**k:print("unlink",p)
exec(compile(${JSON.stringify(FS_PROGRAM)},"fs","exec"))
`
const remove = (path: string) => {
  const r = spawnSync("python3", ["-c", DRY, "remove", path], { encoding: "utf8" })
  return { code: r.status, removed: r.stdout.split("\n").filter((l) => /^(rmtree|unlink) /.test(l)) }
}

const root = mkdtempSync(join(tmpdir(), "cmux-fs-program-"))
mkdirSync(join(root, "target"))
writeFileSync(join(root, "target", "file"), "x")
symlinkSync(join(root, "target"), join(root, "link"))
symlinkSync("/", join(root, "rootlink"))
afterAll(() => rmSync(root, { recursive: true, force: true }))

describe.skipIf(!python)("the fs program's remove", () => {
  it("refuses a path that resolves to the root, removing nothing", () => {
    for (const path of [join(root, "rootlink"), `${join(root, "rootlink")}/.`, `${join(root, "rootlink")}/`])
      expect(remove(path), path).toEqual({ code: 47, removed: [] })
  })

  it("removes a symlink named with a trailing / or /. itself, never its target's contents", () => {
    for (const path of [join(root, "link"), `${join(root, "link")}/`, `${join(root, "link")}/.`])
      expect(remove(path), path).toEqual({ code: 0, removed: [`unlink ${join(root, "link")}`] })
  })

  it("removes a directory and a file by name", () => {
    expect(remove(`${join(root, "target")}/.`)).toEqual({ code: 0, removed: [`rmtree ${join(root, "target")}`] })
    expect(remove(join(root, "target", "file"))).toEqual({
      code: 0,
      removed: [`unlink ${join(root, "target", "file")}`],
    })
    expect(remove(join(root, "missing")).code).toBe(44)
  })
})
