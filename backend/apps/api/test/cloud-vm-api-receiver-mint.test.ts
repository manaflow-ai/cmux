import { decodeProtectedHeader, importJWK, jwtVerify } from "jose"
import { expect, it } from "vitest"
import { withReceiver } from "./cloud-vm-api-receiver-support.ts"

const allowSsh = (f: Parameters<Parameters<typeof withReceiver>[0]>[0]) => {
  f.native.peers = [{ deviceId: f.client.device, wgPublicKey: f.client.wg, installPublicKey: f.client.point, allow: [{ protocol: "tcp", port: 22 }] }]
}
const refusal = (reply: any) => ({ ok: reply.ok, code: reply.code })

it("mints only for a ready receiving attempt and signs its generation", async () => withReceiver(async (f) => {
  allowSsh(f)
  expect(refusal(await f.mint())).toMatchObject({ ok: false, code: "auth.forbidden" })
  const initial = await f.lifecycleHttp({ phase: "read" })
  const first = await f.lifecycleHttp({ phase: "begin", expected: initial.json.value.generation, attempt: "a".repeat(32) })
  expect(first.json.ok).toBe(true)
  expect(refusal(await f.mint())).toMatchObject({ ok: false, code: "auth.forbidden" })
  await f.lifecycleHttp({ phase: "ready", expected: first.json.value.generation })
  const minted = await f.mint()
  expect(minted.ok, minted.code ?? minted.message).toBe(true)
  const kid = decodeProtectedHeader(minted.value.token).kid!
  const key = await importJWK(f.keyset[kid]!, "EdDSA")
  const { payload } = await jwtVerify(minted.value.token, key, { audience: f.host, algorithms: ["EdDSA"] })
  expect(payload.receiver).toEqual({ version: 2, generation: first.json.value.generation })
  expect(JSON.stringify(payload)).not.toContain(f.principal.grant)
  await f.lifecycleHttp({ phase: "end", expected: first.json.value.generation })
  expect(refusal(await f.mint())).toMatchObject({ ok: false, code: "auth.forbidden" })
  const second = await f.lifecycleHttp({ phase: "begin", expected: first.json.value.generation, attempt: "b".repeat(32) })
  await f.lifecycleHttp({ phase: "ready", expected: second.json.value.generation })
  const replacement = await f.mint()
  expect(replacement.ok, replacement.code ?? replacement.message).toBe(true)
  const checked = await jwtVerify(replacement.value.token, key, { audience: f.host, algorithms: ["EdDSA"] })
  expect(checked.payload.receiver).toEqual({ version: 2, generation: second.json.value.generation })
  expect(second.json.value.generation).not.toBe(first.json.value.generation)
}))

it.each(["before", "during"] as const)("rechecks the original VM grant %s client authorization", async (when) => withReceiver(async (f) => {
  allowSsh(f)
  const initial = await f.lifecycleHttp({ phase: "read" })
  const first = await f.lifecycleHttp({ phase: "begin", expected: initial.json.value.generation, attempt: "c".repeat(32) })
  expect(first.json.ok).toBe(true)
  expect((await f.lifecycleHttp({ phase: "ready", expected: first.json.value.generation })).json.ok).toBe(true)
  if (when === "before") await f.grant("vm", { revoked_at: Date.now() })
  else f.onDial(() => f.grant("vm", { revoked_at: Date.now() }))
  expect(refusal(await f.mint())).toMatchObject({ ok: false, code: "auth.forbidden" })
  expect((await f.audit()).filter((entry) => entry.op === "link_token")).toHaveLength(0)
}))

it("never mints beyond the original receiving VM grant expiry", async () => withReceiver(async (f) => {
  allowSsh(f)
  const expires = Date.now() + 20_000
  await f.grant("vm", { expires_at: expires })
  const initial = await f.lifecycleHttp({ phase: "read" })
  const first = await f.lifecycleHttp({ phase: "begin", expected: initial.json.value.generation, attempt: "d".repeat(32) })
  expect(first.json.ok).toBe(true)
  expect((await f.lifecycleHttp({ phase: "ready", expected: first.json.value.generation })).json.ok).toBe(true)
  const reply = await f.mint()
  expect(reply.ok, reply.code ?? reply.message).toBe(true)
  expect(reply.value.expires_at).toBeLessThanOrEqual(expires)
}))

it("requires a fresh receiving attempt after the original VM is paused and started", async () => withReceiver(async (f) => {
  allowSsh(f)
  const initial = await f.lifecycleHttp({ phase: "read" })
  const first = await f.lifecycleHttp({ phase: "begin", expected: initial.json.value.generation, attempt: "e".repeat(32) })
  expect(first.json.ok).toBe(true)
  expect((await f.lifecycleHttp({ phase: "ready", expected: first.json.value.generation })).json.ok).toBe(true)
  expect(refusal(await f.mint())).toMatchObject({ ok: true })
  const paused = await f.power("pause")
  expect(paused.frames.find((frame) => frame.t === "reject")).toBeUndefined()
  expect(paused.frames.some((frame) => frame.t === "result")).toBe(true)
  expect(await f.self()).toMatchObject({ ok: true, value: { machine: { status: "paused" } } })
  const started = await f.power("start")
  expect(started.frames.find((frame) => frame.t === "reject")).toBeUndefined()
  expect(started.frames.some((frame) => frame.t === "result")).toBe(true)
  expect(await f.self()).toMatchObject({ ok: true, value: { machine: { status: "running" } } })
  expect(refusal(await f.mint())).toMatchObject({ ok: false, code: "auth.forbidden" })
  const policy = await f.readHttp()
  expect(policy.json.ok, policy.json.code).toBe(true)
  expect(policy.json.value.receiver_generation).toBeNull()
  const retired = await f.lifecycleHttp({ phase: "read" })
  expect(retired.json.value).toMatchObject({ generation: first.json.value.generation, phase: "stopped" })
  const next = await f.lifecycleHttp({ phase: "begin", expected: retired.json.value.generation, attempt: "f".repeat(32) })
  expect(next.json.ok, next.json.code).toBe(true)
  expect(next.json.value.generation).not.toBe(first.json.value.generation)
  expect((await f.lifecycleHttp({ phase: "ready", expected: next.json.value.generation })).json.ok).toBe(true)
  expect(refusal(await f.mint())).toMatchObject({ ok: true })
}))
