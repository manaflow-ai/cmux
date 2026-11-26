import { env } from "cloudflare:workers"
import { afterEach, describe, expect, it } from "vitest"
import type { Env } from "../src/env.ts"
import { GITHUB_APP_SLUG_MISS_TTL_MS, GITHUB_APP_SLUG_TTL_MS, githubAppSlug, resetGithubAppSlugCache, type Http } from "../src/integrations/providers.ts"

/** The product App's slug is read from GitHub's GET /app (cached), so renaming the App needs no secret change. */
const base = env as unknown as Env
const app = (slugs: Array<unknown>) => {
  const seen: Array<string> = []
  const http: Http = async (r) => {
    seen.push(`${r.method} ${r.url} ${r.headers.get("authorization")?.split(".").length === 3 ? "jwt" : "none"}`)
    const next = slugs.shift()
    if (next instanceof Error) throw next
    if (typeof next === "number") return new Response("{}", { status: next })
    return Response.json({ id: 1, slug: next, name: "cmux" })
  }
  return { http, seen }
}
afterEach(resetGithubAppSlugCache)

describe("githubAppSlug", () => {
  it("answers GitHub's slug with the App JWT, cached, and a rename after the TTL", async () => {
    const gh = app(["cmux", "cmux-agents"])
    const t = Date.now()
    expect(await githubAppSlug(base, gh.http, t)).toBe("cmux")
    expect(await githubAppSlug(base, gh.http, t + 1_000)).toBe("cmux")
    expect(gh.seen).toEqual(["GET https://api.github.com/app jwt"])
    expect(await githubAppSlug(base, gh.http, t + GITHUB_APP_SLUG_TTL_MS + 1)).toBe("cmux-agents")
    expect(gh.seen).toHaveLength(2)
  })

  it("falls back to the GITHUB_APP_SLUG secret when GitHub fails, and retries after the miss TTL", async () => {
    const gh = app([500, new Error("offline"), "cmux"])
    const t = Date.now()
    expect(await githubAppSlug(base, gh.http, t)).toBe(base.GITHUB_APP_SLUG)
    expect(await githubAppSlug(base, gh.http, t + 1_000)).toBe(base.GITHUB_APP_SLUG)
    expect(gh.seen).toHaveLength(1)
    expect(await githubAppSlug(base, gh.http, t + GITHUB_APP_SLUG_MISS_TTL_MS + 1)).toBe(base.GITHUB_APP_SLUG)
    expect(await githubAppSlug(base, gh.http, t + 2 * GITHUB_APP_SLUG_MISS_TTL_MS + 2)).toBe("cmux")
  })

  it("refuses a slug that is not one, and answers null with no secret and no GitHub", async () => {
    const gh = app(["../evil"])
    expect(await githubAppSlug(base, gh.http)).toBe(base.GITHUB_APP_SLUG)
    resetGithubAppSlugCache()
    expect(await githubAppSlug({ ...base, GITHUB_APP_SLUG: undefined }, app([503]).http)).toBeNull()
    // Without an injected client the test environment never reaches GitHub: the secret answers.
    expect(await githubAppSlug(base)).toBe("cmux-test")
  })

  it("keeps the development App (cmux-cloud-dev) on its own key and slug", async () => {
    const dev = { ...base, GITHUB_APP_CLIENT_ID: "Iv1.dev", GITHUB_APP_SLUG: "cmux-cloud-dev" }
    expect(await githubAppSlug(dev, app(["cmux-cloud-dev"]).http)).toBe("cmux-cloud-dev")
    expect(await githubAppSlug(base, app(["cmux"]).http)).toBe("cmux")
  })
})
