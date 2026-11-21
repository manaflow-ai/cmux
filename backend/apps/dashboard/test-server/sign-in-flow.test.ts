import { describe, expect, test } from "bun:test"
import { autoSignInHref, signInHref } from "../src/lib/return-path"
import {
  ACCESS_COOKIE,
  failedPath,
  FAILED_PATH,
  MAX_NORMALIZED_RETURN_PATH,
  finishSignIn,
  FLOW_COOKIE,
  FLOW_TTL_SECONDS,
  REFRESH_COOKIE,
  s256Challenge,
  safeReturnPath,
  signInConfig,
  startSignIn,
  type SignInConfig
} from "../src/lib/sign-in-flow"

const SECRET = "c".repeat(40)
const config: SignInConfig = signInConfig("console.cmux.dev", { CMUX_SIGN_IN_CLIENT_ID: "cmux-console", CMUX_SIGN_IN_CLIENT_SECRET: SECRET })!
const NOW = 1_800_000_000_000

describe("return path", () => {
  test("keeps same-origin relative paths", () => {
    for (const path of ["/", "/devices", "/integrations/callback?state=abc&code=xyz&installation_id=1", "/team?x=1#frag", "/a/b%2F%2Fc"]) {
      expect(safeReturnPath(path)).toBe(path)
    }
  })

  test("answers a percent-encoded ASCII path, so the redirect header is always valid", () => {
    const path = safeReturnPath("/integrations/callback?repo=日本&x=é")
    expect(path).toBe("/integrations/callback?repo=%E6%97%A5%E6%9C%AC&x=%C3%A9")
    expect(() => new Headers({ location: path })).not.toThrow()
    expect(safeReturnPath("/日本")).toBe("/%E6%97%A5%E6%9C%AC")
  })

  test("caps the normalized path so the flow cookie always fits", () => {
    const fits = `/${"a".repeat(MAX_NORMALIZED_RETURN_PATH - 1)}`
    expect(safeReturnPath(fits)).toBe(fits)
    expect(safeReturnPath(`${fits}a`)).toBe("/")
    // Percent-encoding counts: 700 three-byte characters become 6300 characters.
    expect(safeReturnPath(`/${"日".repeat(700)}`)).toBe("/")
  })

  test("refuses every open-redirect form", () => {
    const bad: unknown[] = [
      "//evil.example",
      "//evil.example/path",
      "/\\evil.example",
      "\\\\evil.example",
      "https://evil.example",
      "http:evil.example",
      "javascript:alert(1)",
      "data:text/html,x",
      "evil.example",
      "",
      " /devices",
      "/\t/evil.example",
      "/\n/evil.example",
      "/\r\n/evil.example",
      "/devices\\..\\..",
      "/x\u0000",
      "/x\u007f",
      "/auth/handoff?code=x",
      "/auth/sign-in?return_to=//evil",
      `/${"a".repeat(3000)}`,
      undefined,
      null,
      42,
      ["/devices"]
    ]
    for (const path of bad) expect(safeReturnPath(path)).toBe("/")
  })
})

describe("config", () => {
  test("only the known consoles, each with its own client and cmux.com deployment", () => {
    expect(config).toEqual({ clientId: "cmux-console", issuer: "https://cmux.com", redirectUri: "https://console.cmux.dev/auth/handoff", clientSecret: SECRET })
    expect(signInConfig("console-staging.cmux.dev", { CMUX_SIGN_IN_CLIENT_ID: "cmux-console-staging", CMUX_SIGN_IN_CLIENT_SECRET: SECRET })).toEqual({
      clientId: "cmux-console-staging",
      issuer: "https://cmux-staging.vercel.app",
      redirectUri: "https://console-staging.cmux.dev/auth/handoff",
      clientSecret: SECRET
    })
    expect(signInConfig("evil.example", { CMUX_SIGN_IN_CLIENT_ID: "cmux-console", CMUX_SIGN_IN_CLIENT_SECRET: SECRET })).toBeNull()
    expect(signInConfig("localhost:3010", { CMUX_SIGN_IN_CLIENT_SECRET: SECRET })).toBeNull()
    expect(signInConfig("console.cmux.dev", {})).toBeNull()
    expect(signInConfig("console.cmux.dev", { CMUX_SIGN_IN_CLIENT_ID: "cmux-console", CMUX_SIGN_IN_CLIENT_SECRET: "short" })).toBeNull()
  })

  test("the deployment's pinned client must match the request host", () => {
    const production = { CMUX_SIGN_IN_CLIENT_ID: "cmux-console", CMUX_SIGN_IN_CLIENT_SECRET: SECRET }
    const staging = { CMUX_SIGN_IN_CLIENT_ID: "cmux-console-staging", CMUX_SIGN_IN_CLIENT_SECRET: SECRET }
    // A host header naming the other console never pairs this deployment's secret with that client.
    expect(signInConfig("console-staging.cmux.dev", production)).toBeNull()
    expect(signInConfig("console.cmux.dev", staging)).toBeNull()
    expect(signInConfig("console.cmux.dev", { CMUX_SIGN_IN_CLIENT_SECRET: SECRET })).toBeNull()
    expect(signInConfig("console.cmux.dev", { ...production, CMUX_SIGN_IN_CLIENT_ID: "other" })).toBeNull()
    expect(signInConfig("console.cmux.dev", production)?.clientId).toBe("cmux-console")
  })
})

const setCookies = (response: Response): string[] => response.headers.getSetCookie()

const cookieValue = (response: Response, name: string): string | undefined => {
  const line = setCookies(response).find((c) => c.startsWith(`${name}=`))
  return line?.slice(name.length + 1).split(";")[0]
}

async function start(returnTo?: string) {
  const url = new URL("https://console.cmux.dev/auth/sign-in")
  if (returnTo !== undefined) url.searchParams.set("return_to", returnTo)
  const response = await startSignIn(new Request(url), { config, now: () => NOW })
  const location = new URL(response.headers.get("location")!)
  const flow = cookieValue(response, FLOW_COOKIE)!
  const decoded = JSON.parse(atob(flow.replace(/-/g, "+").replace(/_/g, "/"))) as { state: string; verifier: string; returnTo: string; expiresAt: number }
  return { response, location, flow, decoded }
}

type Call = { url: string; body: Record<string, string>; init: RequestInit }

function issuer(answer: (body: Record<string, string>) => Response) {
  const calls: Call[] = []
  const fetchImpl = (async (url: string | URL | Request, init?: RequestInit) => {
    const body = JSON.parse(String(init?.body)) as Record<string, string>
    calls.push({ url: String(url), body, init: init ?? {} })
    return answer(body)
  }) as typeof fetch
  return { calls, fetchImpl }
}

const handoff = (params: Record<string, string>, cookie?: string) => {
  const url = new URL("https://console.cmux.dev/auth/handoff")
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v)
  return new Request(url, { headers: cookie ? { cookie: `other=1; ${FLOW_COOKIE}=${cookie}` } : {} })
}

describe("start", () => {
  test("sends the browser to cmux.com with a fresh state and an S256 challenge, keeping both in an HttpOnly cookie", async () => {
    const { response, location, decoded } = await start("/integrations/callback?state=s&code=c")
    expect(response.status).toBe(303)
    expect(`${location.origin}${location.pathname}`).toBe("https://cmux.com/handler/console-sign-in")
    expect(location.searchParams.get("client_id")).toBe("cmux-console")
    expect(location.searchParams.get("code_challenge_method")).toBe("S256")
    expect(location.searchParams.get("state")).toBe(decoded.state)
    expect(location.searchParams.get("code_challenge")).toBe(await s256Challenge(decoded.verifier))
    // No verifier, secret or redirect URI in the URL.
    expect(location.toString()).not.toContain(decoded.verifier)
    expect(location.toString()).not.toContain(SECRET)
    expect(location.searchParams.has("redirect_uri")).toBe(false)
    // >= 128-bit state (256 here) and a valid verifier length.
    expect(atob(decoded.state.replace(/-/g, "+").replace(/_/g, "/")).length).toBeGreaterThanOrEqual(16)
    expect(decoded.verifier.length).toBeGreaterThanOrEqual(43)
    expect(decoded.returnTo).toBe("/integrations/callback?state=s&code=c")
    expect(decoded.expiresAt).toBe(NOW + FLOW_TTL_SECONDS * 1000)
    const line = setCookies(response).find((c) => c.startsWith(`${FLOW_COOKIE}=`))!
    expect(line).toContain("HttpOnly")
    expect(line).toContain("Secure")
    expect(line).toContain("SameSite=Lax")
    expect(line).toContain("Path=/")
    expect(line).toContain(`Max-Age=${FLOW_TTL_SECONDS}`)
    expect(FLOW_TTL_SECONDS).toBeLessThanOrEqual(600)
    expect(response.headers.get("cache-control")).toBe("no-store")
  })

  test("validates the return path on start", async () => {
    expect((await start("//evil.example")).decoded.returnTo).toBe("/")
    expect((await start("https://evil.example")).decoded.returnTo).toBe("/")
    expect((await start()).decoded.returnTo).toBe("/")
  })

  test("every start has its own state and verifier", async () => {
    const a = await start("/")
    const b = await start("/")
    expect(a.decoded.state).not.toBe(b.decoded.state)
    expect(a.decoded.verifier).not.toBe(b.decoded.verifier)
  })

  test("an unconfigured console goes to the generic failure", async () => {
    const response = await startSignIn(new Request("https://evil.example/auth/sign-in"), { config: null })
    expect(response.headers.get("location")).toBe(FAILED_PATH)
    expect(setCookies(response)).toEqual([])
  })
})

describe("finish", () => {
  const tokens = () => Response.json({ access_token: "at.jwt.value", refresh_token: "rt-value" })

  test("redeems the code server to server and sets the session cookies", async () => {
    const { flow, decoded } = await start("/integrations/callback?state=s&code=c")
    const { calls, fetchImpl } = issuer(tokens)
    const response = await finishSignIn(handoff({ code: "the-code", state: decoded.state }, flow), { config, fetch: fetchImpl, now: () => NOW })
    expect(response.status).toBe(303)
    expect(response.headers.get("location")).toBe("/integrations/callback?state=s&code=c")
    expect(calls).toHaveLength(1)
    expect(calls[0]!.url).toBe("https://cmux.com/handler/console-sign-in/token")
    expect(calls[0]!.init.method).toBe("POST")
    expect(calls[0]!.body).toEqual({ client_id: "cmux-console", client_secret: SECRET, code: "the-code", code_verifier: decoded.verifier, redirect_uri: "https://console.cmux.dev/auth/handoff" })
    expect(cookieValue(response, ACCESS_COOKIE)).toBe("at.jwt.value")
    expect(cookieValue(response, REFRESH_COOKIE)).toBe("rt-value")
    for (const line of setCookies(response)) {
      expect(line).toContain("HttpOnly")
      expect(line).toContain("Secure")
    }
    // The flow cookie is cleared, and no token is in the redirect.
    expect(setCookies(response).find((c) => c.startsWith(`${FLOW_COOKIE}=`))).toContain("Max-Age=0")
    expect(response.headers.get("location")).not.toContain("at.jwt.value")
    expect(response.headers.get("referrer-policy")).toBe("no-referrer")
  })

  test("a state that does not match the cookie is refused, the cookie cleared and the code burned", async () => {
    const { flow, decoded } = await start("/devices")
    const { calls, fetchImpl } = issuer(tokens)
    const injected = "i".repeat(43)
    const response = await finishSignIn(handoff({ code: injected, state: "attacker-state-aaaaaaaaaaaaaa" }, flow), { config, fetch: fetchImpl, now: () => NOW })
    expect(response.headers.get("location")).toBe(failedPath("/devices"))
    expect(cookieValue(response, ACCESS_COOKIE)).toBeUndefined()
    expect(setCookies(response).find((c) => c.startsWith(`${FLOW_COOKIE}=`))).toContain("Max-Age=0")
    // The only call burns the code with a verifier that is not this flow's.
    expect(calls).toHaveLength(1)
    expect(calls[0]!.body.code).toBe(injected)
    expect(calls[0]!.body.code_verifier).not.toBe(decoded.verifier)
  })

  test("a code with no flow cookie (login CSRF) is refused", async () => {
    const { calls, fetchImpl } = issuer(tokens)
    const response = await finishSignIn(handoff({ code: "a".repeat(43), state: "attacker-state-aaaaaaaaaaaaaa" }), { config, fetch: fetchImpl, now: () => NOW })
    expect(response.headers.get("location")).toBe(FAILED_PATH)
    expect(cookieValue(response, ACCESS_COOKIE)).toBeUndefined()
    expect(calls.every((c) => c.body.code_verifier.length >= 43)).toBe(true)
    // A malformed code is not worth a request to cmux.com.
    const before = calls.length
    await finishSignIn(handoff({ code: "not-a-code", state: "attacker-state-aaaaaaaaaaaaaa" }), { config, fetch: fetchImpl, now: () => NOW })
    expect(calls.length).toBe(before)
  })

  test("an expired flow cookie is refused", async () => {
    const { flow, decoded } = await start("/devices")
    const { fetchImpl } = issuer(tokens)
    const response = await finishSignIn(handoff({ code: "c", state: decoded.state }, flow), { config, fetch: fetchImpl, now: () => NOW + FLOW_TTL_SECONDS * 1000 })
    expect(response.headers.get("location")).toBe(FAILED_PATH)
    expect(cookieValue(response, ACCESS_COOKIE)).toBeUndefined()
  })

  test("a failure on an integration callback offers a retry back to the same callback", async () => {
    const callback = "/integrations/callback?state=st&code=gh&installation_id=7"
    const { flow, decoded } = await start(callback)
    const { fetchImpl } = issuer(() => Response.json({ error: "invalid_grant" }, { status: 400 }))
    const response = await finishSignIn(handoff({ code: "c", state: decoded.state }, flow), { config, fetch: fetchImpl, now: () => NOW })
    const location = new URL(response.headers.get("location")!, "https://console.cmux.dev")
    expect(location.pathname).toBe("/")
    expect(location.searchParams.get("signin")).toBe("failed")
    expect(location.searchParams.get("return_to")).toBe(callback)
    // The retry link goes through the same validated start.
    expect(new URL(signInHref(location.searchParams.get("return_to")!), "https://console.cmux.dev").searchParams.get("return_to")).toBe(callback)
    expect(failedPath("//evil.example")).toBe(FAILED_PATH)
    expect(failedPath("/")).toBe(FAILED_PATH)
  })

  test("the longest kept return path still round-trips through the flow cookie", async () => {
    const long = `/integrations/callback?x=${"a".repeat(MAX_NORMALIZED_RETURN_PATH - 30)}`
    const { flow, decoded, response: started } = await start(long)
    expect(decoded.returnTo).toBe(long)
    const line = setCookies(started).find((c) => c.startsWith(`${FLOW_COOKIE}=`))!
    expect(line.length).toBeLessThan(4000)
    const { fetchImpl } = issuer(tokens)
    const response = await finishSignIn(handoff({ code: "c", state: decoded.state }, flow), { config, fetch: fetchImpl, now: () => NOW })
    expect(response.headers.get("location")).toBe(long)
  })

  test("a PKCE refusal (or any issuer error) is one generic failure", async () => {
    for (const answer of [
      () => Response.json({ error: "invalid_grant" }, { status: 400 }),
      () => Response.json({ error: "invalid_client" }, { status: 401 }),
      () => Response.json({ access_token: "only-access" }),
      () => new Response("not json"),
      () => {
        throw new Error("network")
      }
    ]) {
      const { flow, decoded } = await start("/devices")
      const { fetchImpl } = issuer(answer)
      const response = await finishSignIn(handoff({ code: "c", state: decoded.state }, flow), { config, fetch: fetchImpl, now: () => NOW })
      expect(response.headers.get("location")).toBe(failedPath("/devices"))
      expect(cookieValue(response, ACCESS_COOKIE)).toBeUndefined()
      expect(setCookies(response).find((c) => c.startsWith(`${FLOW_COOKIE}=`))).toContain("Max-Age=0")
    }
  })

  test("a non-ASCII return path still finishes with a valid redirect", async () => {
    const { flow, decoded } = await start("/integrations/callback?repo=日本")
    const { fetchImpl } = issuer(tokens)
    const response = await finishSignIn(handoff({ code: "c", state: decoded.state }, flow), { config, fetch: fetchImpl, now: () => NOW })
    expect(response.headers.get("location")).toBe("/integrations/callback?repo=%E6%97%A5%E6%9C%AC")
    expect(cookieValue(response, ACCESS_COOKIE)).toBe("at.jwt.value")
  })

  test("the return path is validated again on finish", async () => {
    const state = "s".repeat(43)
    const forged = btoa(JSON.stringify({ state, verifier: "v".repeat(43), returnTo: "//evil.example", expiresAt: NOW + 1000 })).replace(/=+$/, "").replace(/\+/g, "-").replace(/\//g, "_")
    const { fetchImpl } = issuer(tokens)
    const response = await finishSignIn(handoff({ code: "c", state }, forged), { config, fetch: fetchImpl, now: () => NOW })
    expect(response.headers.get("location")).toBe("/")
  })
})

describe("integrations callback when signed out", () => {
  const memory = () => {
    const values = new Map<string, string>()
    return { getItem: (k: string) => values.get(k) ?? null, setItem: (k: string, v: string) => void values.set(k, v) }
  }
  const here = { pathname: "/integrations/callback", search: "?state=st&code=gh-code&installation_id=7&setup_action=install" }

  test("starts the flow with the callback URL as the return path", () => {
    const href = autoSignInHref(false, here, memory(), NOW)
    expect(href).toBe(signInHref("/integrations/callback?state=st&code=gh-code&installation_id=7&setup_action=install"))
    const url = new URL(href!, "https://console.cmux.dev")
    expect(url.pathname).toBe("/auth/sign-in")
    expect(safeReturnPath(url.searchParams.get("return_to"))).toBe(`${here.pathname}${here.search}`)
  })

  test("does nothing while loading or signed in", () => {
    expect(autoSignInHref(null, here, memory(), NOW)).toBeNull()
    expect(autoSignInHref(true, here, memory(), NOW)).toBeNull()
  })

  test("does not loop: a second automatic start within two minutes shows the link instead", () => {
    const storage = memory()
    expect(autoSignInHref(false, here, storage, NOW)).not.toBeNull()
    expect(autoSignInHref(false, here, storage, NOW + 30_000)).toBeNull()
    expect(autoSignInHref(false, here, storage, NOW + 3 * 60_000)).not.toBeNull()
    expect(autoSignInHref(false, here, null, NOW)).toBeNull()
  })
})
