import { expect } from "vitest"
import { b64u, call, testEnv } from "./pairing-harness.ts"

/** Register and prove an actual app key, including the selected team in the challenge. */
export const authorityClient = async (session: string, user: string, team?: string) => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])
  if (!("privateKey" in pair)) throw new Error("missing app key")
  const public_jwk = await crypto.subtle.exportKey("jwk", pair.publicKey)
  const registered = await call("/v1/ops", session, {
    op: "install.register", params: { public_jwk, kind: "mac", name: "Laptop", device_name: "Laptop", platform: "macos" },
    idempotency_key: crypto.randomUUID(), origin: "user"
  })
  expect(registered.json.ok, JSON.stringify(registered.json)).toBe(true)
  const install = registered.json.value.id as string
  const challenge = await call("/v1/auth/challenge", undefined, { user, install, ...(team ? { team } : {}) })
  expect(challenge.status).toBe(200)
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey,
    new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`))
  const issued = await call("/v1/auth/token", undefined, { user, install, nonce: challenge.json.nonce, signature: b64u(signature) })
  expect(issued.status, JSON.stringify(issued.json)).toBe(200)
  const token = issued.json.access_token as string, grant = issued.json.grant as string, selected = issued.json.team as string
  const principal = { identity: `install:${install}`, kind: "install" as const, user, install, grant, team: selected }
  const stub = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user)) as any
  const read = (params: unknown = {}) => call("/v1/read", token, { op: "install.authority", params })
  const version = async () => {
    const r = await read()
    expect(r.status, JSON.stringify(r.json)).toBe(200)
    expect(r.json.value).toMatchObject({ user, install, grant, team: selected, authority_version: expect.stringMatching(/^[0-9a-f]{64}$/) })
    expect(Object.keys(r.json.value).sort()).toEqual(["authority_version", "grant", "install", "team", "user"])
    return r.json.value.authority_version as string
  }
  return { token, install, grant, team: selected, user, principal, stub, read, version }
}
