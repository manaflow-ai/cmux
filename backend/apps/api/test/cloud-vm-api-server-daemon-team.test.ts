import { expect, it } from "vitest"
import { personalTeamIdFor } from "../src/domains/user.ts"
import { b64u, beginPairing, call } from "./pairing-harness.ts"
import { rolesTeam } from "./team-roles-support.ts"

it("mints a paired daemon's token for its approved shared team without letting it switch into the owner's personal team", async () => {
  const team = await rolesTeam(), begun = await beginPairing(Date.now(), false, crypto.randomUUID())
  const approved = await call("/v1/ops", team.creator.token, {
    op: "server.pair.approve", params: { code: begun.res.json.code, team: team.team, name: "Shared server" }, idempotency_key: crypto.randomUUID(), origin: "cli"
  }, { "x-cmux-team": team.team })
  expect(approved.json.ok).toBe(true)
  const paired = { user: approved.json.value.user as string, install: approved.json.value.install as string }
  const challenge = await call("/v1/auth/challenge", undefined, paired)
  expect(challenge.status).toBe(200)
  const signature = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, begun.pair.privateKey, new TextEncoder().encode(`${challenge.json.message_prefix}${challenge.json.nonce}`))
  const token = await call("/v1/auth/token", undefined, { ...paired, nonce: challenge.json.nonce, signature: b64u(signature) })
  expect(token.status).toBe(200)
  expect(token.json.team).toBe(team.team)
  const directory = await call("/v1/read", token.json.access_token, { op: "team.directory", params: {} })
  expect(directory.json.value?.team).toBe(team.team)
  const other = await call("/v1/read", token.json.access_token, { op: "team.directory", params: {} }, { "x-cmux-team": personalTeamIdFor(paired.user) })
  expect(other.status).toBe(403)
})
