// The fs routes' guest program (src/cloud-machine-guest.ts FS_PROGRAM), run with the local python3 on a
// temporary tree. shutil.rmtree and os.unlink are replaced by prints first, so no run can delete anything: the
// test reads which path each would have removed.
import { spawnSync } from "node:child_process"
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { afterAll, describe, expect, it } from "vitest"
import { DIR_MAX_BYTES, FS_PROGRAM } from "../src/cloud-machine-guest.ts"

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

describe.skipIf(!python)("the fs program's dir", () => {
  // Names of control characters: json.dumps writes each byte as a 6-byte \u0001 escape (an entry is about 1.6 KB).
  const listing = (count: number) => {
    const dir = mkdtempSync(join(root, "dir-"))
    for (let n = 0; n < count; n++) writeFileSync(join(dir, "\u0001".repeat(245) + String(n).padStart(10, "0")), "")
    const r = spawnSync("python3", ["-c", FS_PROGRAM, "dir", dir], { encoding: "latin1", maxBuffer: 64 * 1024 * 1024 })
    return { code: r.status, stdout: r.stdout }
  }
  const entryBytes = 255 * 6 + 100

  it("answers a listing of at most DIR_MAX_BYTES, printable ASCII only", () => {
    const count = Math.floor(DIR_MAX_BYTES / entryBytes) - 10
    const r = listing(count)
    expect(r.code).toBe(0)
    expect(r.stdout.length).toBeLessThanOrEqual(DIR_MAX_BYTES)
    expect(/^[\x20-\x7e]*$/.test(r.stdout)).toBe(true)
    expect(JSON.parse(r.stdout).entries).toHaveLength(count)
  })

  it("refuses a listing over DIR_MAX_BYTES with the too-large exit, under the entry count", () => {
    const r = listing(Math.ceil(DIR_MAX_BYTES / (255 * 6)) + 10)
    expect(r).toEqual({ code: 46, stdout: "" })
  })
})
