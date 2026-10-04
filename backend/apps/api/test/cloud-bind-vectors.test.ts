import { cloudOpByName } from "@cmux/protocol"
import { Exit, Schema } from "effect"
import { describe, expect, it } from "vitest"
import vectors from "../../../catalog/cloud-vectors.json"
import { bindFile, cloudStub, DAEMON, post, signedInWithInstall, SIZE, WG_KEY } from "./cloud-bind-support.ts"

/**
 * The bind, connect_info and link_token cases of backend/catalog/cloud-vectors.json answer with the
 * same status, envelope keys, value shape and error code through the Worker (5.8, contract 1.7).
 */

interface VectorCase {
  readonly name: string
  readonly op: string
  readonly responses: ReadonlyArray<{ readonly http: { readonly path: string; readonly status: number }; readonly body: Record<string, any> }>
}
const cases = (vectors as unknown as { cases: ReadonlyArray<VectorCase> }).cases
const keys = (o: object) => Object.keys(o).sort()
const like = (name: string, got: { status: number; body: any }) => {
  const c = cases.find((x) => x.name === name)
  if (!c) throw new Error(`no vector ${name}`)
  const v = c.responses[0]!
  expect(got.status, `${name}: ${JSON.stringify(got.body)}`).toBe(v.http.status)
  expect(keys(got.body), name).toEqual(keys(v.body))
  if (v.body.value && typeof v.body.value === "object") {
    expect(keys(got.body.value), name).toEqual(keys(v.body.value))
    const def = cloudOpByName.get(c.op)
    if (def) expect(Exit.isSuccess(Schema.decodeUnknownExit(def.result as Schema.Codec<unknown, unknown>)(got.body.value)), name).toBe(true)
  }
  if (v.body.error) expect(got.body.error.code, name).toBe(v.body.error.code)
  if (v.body._tag) expect([got.body._tag, got.body.code], name).toEqual([v.body._tag, v.body.code])
  if ("stream" in v.body) expect(got.body.stream === "" ? "" : "cloud:team", name).toBe(v.body.stream === "" ? "" : "cloud:team")
}

describe("bind, connect_info and link_token vector shapes through the Worker", { timeout: 60_000 }, () => {
  it("matches every new case", async () => {
    const a = await signedInWithInstall("cloud-bind-3")
    const created = await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })
    const machine = created.body.value.machine.id as string
    const { json } = await bindFile(cloudStub(a.team), machine)
    const body = { team: a.team, machine, bind_token: json.bind_token, wg_public_key: WG_KEY, daemon: DAEMON }
    like("machine.bind.invalid", await post("/v1/cloud/bind", undefined, { team: a.team, machine }))
    const bound = await post("/v1/cloud/bind", undefined, body)
    like("machine.bind", bound)
    like("machine.bind.spent", await post("/v1/cloud/bind", undefined, body))
    const host = bound.body.value.host as string
    like("machine.connect_info", await post("/v1/read", a.installToken, { op: "cloud.machine.connect_info", params: { machine } }))
    like("machine.connect_info.by_host", await post("/v1/read", a.installToken, { op: "cloud.machine.connect_info", params: { host } }))
    like("machine.connect_info.both_selectors", await post("/v1/read", a.installToken, { op: "cloud.machine.connect_info", params: { machine, host } }))
    const unbound = (await post("/v1/ops", a.session, { op: "cloud.machine.create", params: { size: SIZE }, idempotency_key: crypto.randomUUID(), origin: "user" })).body.value.machine.id
    like("machine.connect_info.not_bound", await post("/v1/read", a.installToken, { op: "cloud.machine.connect_info", params: { machine: unbound } }))
    like("machine.link_token", await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host, services: ["daemon", "ssh"] }, origin: "cli" }))
    like("machine.link_token.key_refused", await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host, services: ["ssh"] }, idempotency_key: "k", origin: "cli" }))
    like("machine.link_token.session_forbidden", await post("/v1/ops", a.session, { op: "cloud.machine.link_token", params: { host, services: ["ssh"] }, origin: "cli" }))
    like("machine.link_token.not_found", await post("/v1/ops", a.installToken, { op: "cloud.machine.link_token", params: { host: "host_h0000000000000000009", services: ["ssh"] }, origin: "cli" }))
  })
})
