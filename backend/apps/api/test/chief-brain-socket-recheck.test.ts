import { describe, expect, it } from "vitest"
import { b64u, beginPairing, call, holdTeamUserRevoke, op, read, returnNextRPC, sessionToken, testEnv, waitFor, worker } from "./pairing-harness.ts"
import { fireAlarm } from "./setup/alarm.ts"

/**
 * A placed Chief's server keeps its chief rights only while TeamDO confirms it, also on a socket
 * opened before the change: every mutating frame of a placed-chief token is checked again (no cache),
 * and a TeamDO that cannot answer refuses (fail closed). Review of the revoke race, backend lead.
 */
const runAlarm = fireAlarm as unknown as (stub: unknown) => Promise<boolean>
const AGENT_GAP_MS = 2_100

const placedChief = async (name: string) => {
  const owner = await sessionToken(name)
  const user = (await op(owner, "user.ensure", {})).json.value.id as string
  const { res, pair } = await beginPairing()
  const code = res.json.code as string
  const waiter = await waitFor(code, res.json.collect_secret)
  const team = (await read(owner, "team.directory", {})).json.value.team as string
  const server = (await op(owner, "server.pair.approve", { code, team, name: "Brain" })).json.value as { host: string; install: string; user: string }
  await waiter.until(() => waiter.frames.some((f) => f.t === "paired"))
  const chief = (await op(owner, "chief.create", { brain_place: { host: server.host, install: server.install } }, "chief-default")).json.value
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20 && (await read(owner, "conversation.history", { conversation: chief.main_conversation, limit: 1 })).status !== 200; i++) await runAlarm(userDO)
  const ch = await call("/v1/auth/challenge", undefined, { user: server.user, install: server.install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const token = (await call("/v1/auth/token", undefined, { user: server.user, install: server.install, nonce: ch.json.nonce, signature: b64u(sig), agent: chief.id })).json.access_token as string
  const ask = (id: string) => op(owner, "message.send", { conversation: chief.main_conversation, client_msg_id: id, parts: [{ type: "text", text: id }] }, id)
  return { owner, user, team, server, chief, userDO, token, ask }
}

/** The chief's socket on its main conversation: op frames, their answers, and a close. */
const chiefSocket = async (conversation: string, token: string) => {
  const res = await worker.fetch(`https://api.test/v1/wire/conv/${conversation}`, { headers: { Upgrade: "websocket", "Sec-WebSocket-Protocol": `cmux.wire.v1, bearer.${token}` } })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const frames: Array<any> = []
  let closed: number | undefined
  let wake: (() => void) | undefined
  ws.addEventListener("message", (e) => {
    frames.push(JSON.parse(e.data as string))
    wake?.()
  })
  ws.addEventListener("close", (e) => {
    closed = e.code
    wake?.()
  })
  ws.accept()
  /** Sends message.send and waits for its result, its refusal, or the socket's close. */
  const send = async (id: string) => {
    ws.send(JSON.stringify({ t: "op", op: "message.send", params: { conversation, client_msg_id: id, parts: [{ type: "text", text: id }] }, idempotency_key: id }))
    for (;;) {
      const answer = frames.find((f) => f.idempotency_key === id && ["result", "reject", "error"].includes(f.t))
      if (answer) return answer
      if (closed !== undefined) return { t: "closed", code: closed }
      await new Promise<void>((r) => (wake = r))
    }
  }
  return { send }
}

const chiefSaid = async (owner: string, conversation: string, id: string) => {
  const history = (await read(owner, "conversation.history", { conversation, limit: 20 })).json.value
  return (history.messages as Array<{ client_msg_id: string }>).some((m) => m.client_msg_id === id)
}

describe("placed chief rights on an open socket", { timeout: 60_000 }, () => {
  it("refuses the next frame after TeamDO revokes the server, while the UserDO push is held back", async () => {
    const t = await placedChief("socket-recheck-revoke")
    const sock = await chiefSocket(t.chief.main_conversation, t.token)
    await t.ask("ask-1")
    expect((await sock.send("before")).t).toBe("result")
    await holdTeamUserRevoke(testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(t.team)), "push held back")
    expect((await op(t.owner, "server.revoke", { host: t.server.host })).json.ok).toBe(true)
    await t.ask("ask-2")
    await new Promise((r) => setTimeout(r, AGENT_GAP_MS))
    const after = await sock.send("after-revoke")
    expect(after.t, JSON.stringify(after)).not.toBe("result")
    expect(await chiefSaid(t.owner, t.chief.main_conversation, "after-revoke")).toBe(false)
  })

  it("refuses the next frame after the chief is moved off the server (brain_place: null)", async () => {
    const t = await placedChief("socket-recheck-move")
    const sock = await chiefSocket(t.chief.main_conversation, t.token)
    await t.ask("ask-1")
    expect((await sock.send("before")).t).toBe("result")
    expect((await op(t.owner, "chief.update", { chief: t.chief.id, expected_rev: t.chief.rev, brain_place: null })).json.ok).toBe(true)
    await t.ask("ask-2")
    await new Promise((r) => setTimeout(r, AGENT_GAP_MS))
    const after = await sock.send("after-move")
    expect(after.t, JSON.stringify(after)).not.toBe("result")
    expect(await chiefSaid(t.owner, t.chief.main_conversation, "after-move")).toBe(false)
  })

  it("refuses a send when TeamDO cannot confirm the server (fail closed)", async () => {
    const t = await placedChief("socket-recheck-teamdo-down")
    await t.ask("ask-1")
    const teamDO = testEnv.TEAM_DO.get(testEnv.TEAM_DO.idFromName(t.team))
    await returnNextRPC(teamDO, "serverPlacementActive", false)
    const sent = (await op(t.token, "message.send", { conversation: t.chief.main_conversation, client_msg_id: "teamdo-down", parts: [{ type: "text", text: "x" }] }, "teamdo-down")).json
    expect(sent.ok, JSON.stringify(sent)).not.toBe(true)
    expect(await chiefSaid(t.owner, t.chief.main_conversation, "teamdo-down")).toBe(false)
  })
})
