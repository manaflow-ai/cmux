import { spawnSync } from "node:child_process"
import { existsSync, mkdtempSync, readFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { describe, expect, test } from "vitest"
import { environmentBuildCommand, environmentBuildExec } from "../src/index.ts"
import { spec } from "./fixtures.ts"

// The rendered script runs for real in bash, in a scratch home with the test seams set.
const home = () => mkdtempSync(join(tmpdir(), "cmux-env-test-"))
const run = (command: string, h: string) =>
  spawnSync("bash", ["-c", command], {
    env: { ...process.env, HOME: "/nonexistent", CMUX_ENVIRONMENT_HOME: h, CMUX_ENVIRONMENT_PROFILE_DIR: join(h, "p"), CMUX_ENVIRONMENT_SUDO: "" },
    encoding: "utf8"
  })

describe("environmentBuildCommand", () => {
  test("writes plain variables, never secret values, runs the setup in the work dir and marks the snapshot", () => {
    const h = home()
    const s = spec({ repo: null, setupScript: 'pwd > "$HOME/setup-cwd"; echo "$NODE_ENV" > "$HOME/setup-env"' })
    const r = run(environmentBuildExec(s, "d0"), h)
    expect(r.status).toBe(0)
    expect(readFileSync(join(h, "setup-cwd"), "utf8").trim()).toBe(join(h, "work"))
    expect(readFileSync(join(h, "setup-env"), "utf8")).toBe("development\n")
    const profile = readFileSync(join(h, "p", "cmux-environment.sh"), "utf8")
    expect(profile).toContain("NODE_ENV")
    expect(profile).not.toContain("OPENAI_API_KEY")
    expect(JSON.parse(readFileSync(join(h, ".cmux", "environment.json"), "utf8"))).toEqual({ digest: "d0", secrets: ["OPENAI_API_KEY"] })
  })

  test("hostile values cannot break out of the script", () => {
    const h = home()
    const hostile = "'; touch \"$HOME/pwned\" #\n$(touch \"$HOME/pwned2\")`touch $HOME/pwned3`"
    expect(run(environmentBuildCommand(spec({ repo: null, setupScript: "", env: [{ name: "X", value: hostile }] }), "d"), h).status).toBe(0)
    for (const f of ["pwned", "pwned2", "pwned3"]) expect(existsSync(join(h, f))).toBe(false)
    const sourced = spawnSync("bash", ["-c", `. "${h}/p/cmux-environment.sh"; printf %s "$X"`], { encoding: "utf8" })
    expect(sourced.stdout).toBe(hostile)
  })

  test("a failing setup fails the build with its exit code", () => {
    expect(run(environmentBuildCommand(spec({ repo: null, setupScript: "echo before; exit 7" }), "d"), home()).status).toBe(7)
  })

  test("a repo is cloned into ~/work/<name> and the setup runs in it", () => {
    const h = home()
    const origin = join(h, "origin")
    spawnSync("bash", ["-c", `git init -q -b main ${origin} && cd ${origin} && echo hi > f && git -c user.email=a@b -c user.name=a add f && git -c user.email=a@b -c user.name=a commit -qm i`])
    // A file:// remote stands in for github.com: rewrite the URL the script clones.
    const s = spec({ repo: "acme/widget@main", setupScript: 'cat f > "$HOME/setup-saw"' })
    const command = environmentBuildCommand(s, "d").replaceAll("https://github.com/acme/widget.git", `file://${origin}`)
    expect(run(command, h).status).toBe(0)
    expect(readFileSync(join(h, "setup-saw"), "utf8")).toBe("hi\n")
    expect(existsSync(join(h, "work", "widget", ".git"))).toBe(true)
  })
})
