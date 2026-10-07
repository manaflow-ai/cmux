import { env, exports } from "cloudflare:workers"
import { runInDurableObject } from "cloudflare:test"
import type { ReduceContext } from "@cmux/ownership"
import { policyKeys } from "@cmux/protocol"
import { importJWK, SignJWT, type JWK } from "jose"
import { describe, expect, it } from "vitest"
import { teamDomain, type TeamState } from "../src/domains/team.ts"
import { currentPolicy, integrationSlice, POLICY_HISTORY_LIMIT } from "../src/domains/team-policy.ts"
import { integrationSyncPending, sliceHash } from "../src/domains/team-integration-sync.ts"
import { fireAlarm } from "./setup/alarm.ts"

const testEnv = env as unknown as { STACK_PROJECT_ID: string; STACK_TEST_PRIVATE_JWK: string; TEAM_DO: DurableObjectNamespace; CONNECTION_DO: DurableObjectNamespace }
const worker = (exports as unknown as { default: Fetcher }).default

const OWNER = "user_00000000000000000001"
const MEMBER = "user_00000000000000000002"
const TEAM = "team_00000000000000000001"

const baseState = (): TeamState => ({
  team: { id: TEAM, kind: "personal", display_name: "T" },
  members: {
    [OWNER]: { user: OWNER, role: "owner", display_name: "o" },
    [MEMBER]: { user: MEMBER, role: "member", display_name: "m" }
  },
  hosts: {}
})

let txn = 0
const ctx = (user = OWNER, extra: Partial<ReduceContext["principal"]> = {}): ReduceContext => ({
  principal: { identity: `user:${user}`, user, team: TEAM, kind: "session", ...extra },
  now: 1_000 + txn,
  tx: `tx${++txn}`,
  newId: (p) => `${p}_${String(txn).padStart(20, "0")}`
})

const run = (state: TeamState, op: string, params: unknown, c = ctx()) => teamDomain.reduce(state, op, params, c)

const set = (key: string, value: unknown, mode: "enforced" | "default" = "enforced") => ({ key, value: { value, mode } })

describe("Cloud connect services policy (FINDER-FS)", () => {
  // FINDER-FS: files are reached only through the link `daemon` service, which also runs commands, so a
  // policy may not grant `daemon` without `ssh` (a principal with daemon but no shell would get shell power
  // through the files path).
  it("cloud.connectServices refuses daemon without ssh and accepts ssh alone or both", () => {
    const s0 = baseState()
    expect(run(s0, "team.policy.update", { changes: [set("cloud.connectServices", ["daemon"])], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
    expect(run(s0, "team.policy.update", { changes: [set("cloud.connectServices", ["ssh"])], expected_version: 0 })).toMatchObject({ ok: true })
    expect(run(s0, "team.policy.update", { changes: [set("cloud.connectServices", ["daemon", "ssh"])], expected_version: 0 })).toMatchObject({ ok: true })
    expect(run(s0, "team.policy.update", { changes: [set("cloud.connectServices", ["ssh", "ssh"])], expected_version: 0 })).toMatchObject({ ok: false, code: "policy.invalid" })
  })
})
