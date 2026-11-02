// scripts/cmux-next/release/mint-link-keyset.mjs mints cmux-platform-production's CLOUD_LINK_SIGNING_KEYS
// (.github/workflows/platform-prod-secrets.yml pipes its stdout into wrangler). Its output must be a keyset
// parseSigningKeys accepts and that signs at once. Run under Node (vitest.node.config.ts): it spawns node.
import { spawnSync } from "node:child_process"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { describe, expect, it } from "vitest"
import { parseSigningKeys, publicKeyset, signingKid } from "../src/link-token.ts"

const script = join(dirname(fileURLToPath(import.meta.url)), "../../../../scripts/cmux-next/release/mint-link-keyset.mjs")
const mint = (...args: string[]) => spawnSync(process.execPath, [script, ...args], { encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] })

describe("mint-link-keyset.mjs", () => {
  it("prints a keyset parseSigningKeys accepts, with one kid that signs now and a public half without d", async () => {
    const r = mint()
    expect(r.status).toBe(0)
    expect(r.stderr).toBe("")
    const keys = parseSigningKeys(r.stdout)
    expect(keys).not.toBeNull()
    const kids = Object.keys(keys!.keys)
    expect(kids).toEqual([keys!.active])
    expect(keys!.active).toBe(`production-${new Date().toISOString().slice(0, 10)}`)
    expect(signingKid(keys!, Date.now())).toBe(keys!.active)
    const pub = await publicKeyset(keys!)
    expect(Object.keys(pub.keys)).toEqual(kids)
    for (const k of Object.values(pub.keys)) expect(k).not.toHaveProperty("d")
  })

  it("mints a different key each run", () => {
    expect(mint().stdout).not.toBe(mint().stdout)
  })

  it("refuses a prefix that makes an invalid kid and prints nothing", () => {
    const r = mint("bad prefix")
    expect(r.status).toBe(2)
    expect(r.stdout).toBe("")
  })
})
