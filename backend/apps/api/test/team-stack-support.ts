import { env } from "cloudflare:workers"
import { createHash } from "node:crypto"
import { expect } from "vitest"
import { signSvixContent } from "../../../../libs/svix-webhook/src/svix.ts"
import { userIdFor } from "../src/domains/user.ts"
import { inDO, sessionToken, testEnv, worker } from "./team-ssh-support.ts"

/** Shared helpers for the Stack team webhook tests (cx-3bi.43): signed deliveries, a fake Stack, a mirrored team. */
export const SECRET = (env as unknown as { STACK_WEBHOOK_SECRET: string }).STACK_WEBHOOK_SECRET
export const PROJECT = testEnv.STACK_PROJECT_ID

/** The cmux id of a Stack team: stable, derived, no lookup (like userIdFor). */
export const teamIdOf = (stackTeam: string) => `team_${createHash("sha256").update(`stack-team:${PROJECT}:${stackTeam}`).digest("hex").slice(0, 20)}`
export const teamStub = (team: string) => testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(team))

/** Stack's truth as the fake server answers it; each TeamDO under test reads it. */
export const stackWorld = () => {
  const teams = new Map<string, string>()
  const members = new Map<string, string>()
  /** `${team}:${user}` -> the member's team permission ids (recursive, as Stack lists them); absent = none. */
  const perms = new Map<string, Array<string>>()
  /** Memberships the cmux side removed in Stack (`${team}:${user}`). */
  const removedInStack: Array<string> = []
  let calls = 0
  const fake = {
    findUserByEmail: async () => undefined,
    createUser: async () => {
      throw new Error("unused")
    },
    createSession: async () => {
      throw new Error("unused")
    },
    getTeam: async (t: string) => {
      calls++
      return teams.has(t) ? { display_name: teams.get(t)! } : null
    },
    listTeamMembers: async (t: string) => {
      calls++
      if (!teams.has(t)) return "team_gone" as const
      return [...members.entries()].filter(([k]) => k.startsWith(`${t}:`)).map(([k, name]) => ({ user_id: k.slice(t.length + 1), display_name: name, permissions: perms.get(k) ?? [] }))
    },
    getTeamMember: async (t: string, u: string) => {
      calls++
      if (!teams.has(t)) return "team_gone" as const
      return members.has(`${t}:${u}`) ? { display_name: members.get(`${t}:${u}`)!, permissions: perms.get(`${t}:${u}`) ?? [] } : null
    },
    removeTeamMember: async (t: string, u: string) => {
      calls++
      if (!teams.has(t)) return "team_gone" as const
      const had = members.delete(`${t}:${u}`)
      perms.delete(`${t}:${u}`)
      if (had) removedInStack.push(`${t}:${u}`)
      return had ? ("removed" as const) : ("absent" as const)
    }
  }
  return { teams, members, perms, removedInStack, fake, calls: () => calls }
}
export type World = ReturnType<typeof stackWorld>

export const useStack = (stackTeam: string, w: World) =>
  inDO(teamStub(teamIdOf(stackTeam)), async (instance) => {
    instance.stack = w.fake
  })

export interface Delivery {
  id?: string
  ts?: number
  secret?: string
  signatures?: (good: string) => string
  /** The exact body to sign and send instead of {type, data}. */
  rawBody?: string
}
export const deliver = async (type: string, data: unknown, o: Delivery = {}) => {
  const body = o.rawBody ?? JSON.stringify({ type, data })
  const id = o.id ?? `msg_${crypto.randomUUID().replace(/-/g, "")}`
  const ts = String(o.ts ?? Math.floor(Date.now() / 1000))
  const good = `v1,${await signSvixContent(o.secret ?? SECRET, `${id}.${ts}.${body}`)}`
  const res = await worker.fetch("https://api.test/v1/hooks/stack", {
    method: "POST",
    headers: { "content-type": "application/json", "svix-id": id, "svix-timestamp": ts, "svix-signature": o.signatures ? o.signatures(good) : good },
    body
  })
  return { status: res.status, body: (await res.json().catch(() => null)) as any, id }
}

export const teamState = (team: string) =>
  inDO(teamStub(team), async (instance) => {
    const engine = instance.boundEngine
    return engine ? { team: engine.currentState.team, member_count: engine.currentState.member_count } : { team: null, member_count: 0 }
  })
export const memberRow = (team: string, user: string) => inDO(teamStub(team), async (instance) => instance.boundEngine?.rows.get("member", user)?.row ?? null)

export const call = async (token: string, path: "/v1/ops" | "/v1/read", body: Record<string, unknown>, team?: string) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}`, ...(team ? { "x-cmux-team": team } : {}) },
    body: JSON.stringify(body)
  })
  return { status: res.status, body: (await res.json().catch(() => null)) as any }
}

/** A Stack team with one Stack member, mirrored through the webhook; the person also exists in cmux. */
export const mirroredTeam = async (name = "Acme") => {
  const w = stackWorld()
  const stackTeam = crypto.randomUUID()
  const stackUser = crypto.randomUUID()
  const team = teamIdOf(stackTeam)
  await useStack(stackTeam, w)
  w.teams.set(stackTeam, name)
  w.members.set(`${stackTeam}:${stackUser}`, "Aziz")
  const token = await sessionToken(stackUser, "Aziz")
  expect((await call(token, "/v1/ops", { op: "user.ensure", params: {}, idempotency_key: crypto.randomUUID(), origin: "cli" })).body.ok).toBe(true)
  expect((await deliver("team.created", { id: stackTeam, display_name: name, profile_image_url: null, created_at_millis: Date.now() })).status).toBe(200)
  expect((await deliver("team_membership.created", { team_id: stackTeam, user_id: stackUser })).status).toBe(200)
  return { w, stackTeam, stackUser, team, user: userIdFor(PROJECT, stackUser), token }
}
