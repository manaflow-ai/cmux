import { describe, expect, test } from "vitest"
import { environmentBuildDigest, environmentSpecBody, parseEnvironmentSpec } from "../src/index.ts"

import { BASE, spec } from "./fixtures.ts"

describe("parseEnvironmentSpec", () => {
  test("accepts repo shorthand, GitHub URLs, tree URLs and no repo", () => {
    expect(spec().repo).toEqual({ owner: "manaflow-ai", name: "cmux", ref: "feat-cmux-next" })
    expect(spec({ repo: "https://github.com/manaflow-ai/cmux.git" }).repo).toEqual({ owner: "manaflow-ai", name: "cmux", ref: null })
    expect(spec({ repo: "https://github.com/manaflow-ai/cmux/tree/feat/x" }).repo).toEqual({ owner: "manaflow-ai", name: "cmux", ref: "feat/x" })
    expect(spec({ repo: null }).repo).toBeNull()
  })

  test.each([
    { repo: "https://user:pw@github.com/a/b" },
    { repo: "https://gitlab.com/a/b" },
    { repo: "a/b@--upload-pack=x" },
    { repo: "a/b@x..y" },
    { repo: "a/b/c" },
    { name: "" },
    { name: "x".repeat(81) },
    { name: "a\u0007b" },
    { setupScript: "x".repeat(64 * 1024 + 1) },
    { setupScript: "echo \u0000" },
    { env: [{ name: "PATH", value: "/x" }] },
    { env: [{ name: "CMUX_TOKEN", value: "x" }] },
    { env: [{ name: "1BAD", value: "x" }] },
    { env: [{ name: "A", value: "x" }, { name: "A", value: "y" }] },
    { env: [{ name: "A", value: "x", secret: "s" }] },
    { env: [{ name: "A" }] },
    { env: [{ name: "A", secret: "bad name!" }] }
  ])("rejects %j", (input) => {
    expect(parseEnvironmentSpec({ name: "e", ...input }).ok).toBe(false)
  })

  test("a spec round-trips through its request body", () => {
    const s = spec()
    const again = parseEnvironmentSpec(environmentSpecBody(s))
    expect(again.ok && again.spec).toEqual(s)
  })
})

describe("environmentBuildDigest", () => {
  test("changes with build inputs, not with the name or variable order", async () => {
    const a = await environmentBuildDigest(spec(), BASE)
    expect(await environmentBuildDigest(spec({ name: "renamed" }), BASE)).toBe(a)
    expect(await environmentBuildDigest(spec({ env: [{ name: "OPENAI_API_KEY", secret: "openai" }, { name: "NODE_ENV", value: "development" }] }), BASE)).toBe(a)
    expect(await environmentBuildDigest(spec({ setupScript: "bun install" }), BASE)).not.toBe(a)
    expect(await environmentBuildDigest(spec({ repo: "manaflow-ai/cmux" }), BASE)).not.toBe(a)
    expect(await environmentBuildDigest(spec(), "sc-newer-base")).not.toBe(a)
    expect(await environmentBuildDigest(spec({ env: [{ name: "NODE_ENV", value: "production" }] }), BASE)).not.toBe(a)
  })
})
