import type { OpFrame, OwnerFrame, Principal } from "@cmux/ownership"
import { expect } from "vitest"
import { teamStub } from "./team-stack-support.ts"
import { inDO, worker } from "./team-ssh-support.ts"

/** Native wire authentication and a real owner subscription, without a polling wait. */
export const listenToTeam = async (token: string, team: string): Promise<WebSocket> => {
  const response = await worker.fetch("https://api.test/v1/wire/team", {
    headers: { Upgrade: "websocket", Authorization: `Bearer ${token}`,
      "Sec-WebSocket-Protocol": `cmux.wire.v1, team.${team}`, "x-cmux-client-version": "2.4.0" }
  })
  expect(response.status).toBe(101)
  const socket = response.webSocket
  if (!socket) throw new Error("team wire did not return a socket")
  const ready = new Promise<void>((resolve, reject) => {
    let deadline: ReturnType<typeof setTimeout> | undefined
    const cleanup = () => {
      if (deadline !== undefined) clearTimeout(deadline)
      socket.removeEventListener("message", message)
      socket.removeEventListener("close", closed)
    }
    const message = (event: MessageEvent) => {
      try {
        if (typeof event.data === "string" && JSON.parse(event.data).t === "snapshot") { cleanup(); resolve() }
      } catch { cleanup(); reject(new Error("invalid team snapshot")) }
    }
    const closed = () => { cleanup(); reject(new Error("team wire closed before its snapshot")) }
    socket.addEventListener("message", message)
    socket.addEventListener("close", closed)
    // A protocol handshake deadline, never a wait for state to settle.
    deadline = setTimeout(() => { cleanup(); reject(new Error("team snapshot deadline exceeded")) }, 10_000)
  })
  socket.accept()
  socket.send(JSON.stringify({ t: "subscribe", pending: [] }))
  try { await ready } catch (error) { closeTeamSocket(socket); throw error }
  return socket
}

export const closeTeamSocket = (socket: WebSocket): void => {
  try { socket.close(1000, "test complete") } catch {}
}

/** Read the real server's open channels after the role commit, without another client frame. */
export const openTeamSockets = (team: string, user: string): Promise<number> =>
  inDO(teamStub(team), async (_instance, state) => state.getWebSockets().filter((socket) =>
    socket.readyState === WebSocket.READY_STATE_OPEN && socket.deserializeAttachment()?.principal?.user === user).length)

/** The same trusted membership op Stack sync uses; callers choose its key to test replay. */
export const provisionRole = (team: string, user: string, role: string, key: string,
  principal: Principal = { kind: "system", identity: "system:team" }): Promise<{ frames: ReadonlyArray<OwnerFrame> }> => {
  const stub = teamStub(team) as unknown as {
    submit(entity: string, principal: Principal, frame: OpFrame): Promise<{ frames: ReadonlyArray<OwnerFrame> }>
  }
  return stub.submit(team, principal, { t: "op", op: "team.member.provision", params: { user, role, display_name: "Member" },
    idempotency_key: key, origin: "script" })
}
