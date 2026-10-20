import { env } from "cloudflare:workers"
import { expect } from "vitest"
import { teamStub } from "./team-stack-support.ts"
import { inDO } from "./team-ssh-support.ts"
import { fireAlarm } from "./setup/alarm.ts"

const namespace = (env as unknown as { CLOUD_DO: DurableObjectNamespace }).CLOUD_DO
export const cloudStub = (team: string) => namespace.get(namespace.idFromName(team))

export const openCloudSockets = (team: string, user: string): Promise<number> =>
  inDO(cloudStub(team), async (_instance, state) => state.getWebSockets().filter((socket) =>
    socket.readyState === WebSocket.READY_STATE_OPEN && socket.deserializeAttachment()?.principal?.user === user).length)

/** Drive the actual durable TeamDO outbox, not a synthetic client frame. */
export const deliverRoleNotices = (team: string) => fireAlarm(teamStub(team))

/** A redelivery trigger carries no authority; CloudDO must read its own team's current membership. */
export const redeliverRoleNotice = async (team: string, user: string, source = `team:${team}`, payloadTeam = team) => {
  const result = await inDO(cloudStub(team), async (instance) => instance.systemDeliver(team, source, [
    { id: 77, op: "team.member_authority.changed", key: `role-notice:${crypto.randomUUID()}`, params: { team: payloadTeam, user } }
  ]))
  expect(result.done).toEqual([77])
}
