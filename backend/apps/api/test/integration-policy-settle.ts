import { env } from "cloudflare:workers"
import { fireAlarm } from "./setup/alarm.ts"


type Call = (token: string, name: string, params: unknown) => Promise<{ json: any }>

/**
 * integration.policy.set is an alias of team.policy.update (F3): TeamDO pushes the slice to
 * ConnectionDO from its alarm. Set, then run TeamDO's alarm until ConnectionDO has it.
 */
export const settlePolicy = async (op: Call, read: Call, token: string, team: string, fields: unknown) => {
  const r = await op(token, "integration.policy.set", fields)
  if (!r.json.ok) return r
  const ns = (env as unknown as { TEAM_DO: DurableObjectNamespace }).TEAM_DO
  const stub = ns.get(ns.idFromName(team))
  const want = JSON.stringify(r.json.value.github) + JSON.stringify(r.json.value.allowed_providers)
  for (let i = 0; i < 50; i++) {
    await fireAlarm(stub)
    const got = (await read(token, "integration.policy.get", {})).json.value
    if (JSON.stringify(got.github) + JSON.stringify(got.allowed_providers) === want) return r
    await new Promise((res) => setTimeout(res, 20))
  }
  throw new Error("integration policy did not reach ConnectionDO")
}
