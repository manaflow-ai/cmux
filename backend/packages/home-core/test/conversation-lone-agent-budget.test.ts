import { describe, expect, it } from "vitest"
import { checkAgentBudget, MAX_AGENT_TURNS, MIN_AGENT_GAP_MS } from "../src/conversation/budget.ts"
import { create } from "../src/conversation/create.ts"
import { agent, CoreHost, human, NOW, text } from "./support/harness.ts"
import { ALICE, BOB, CHIEF, chiefHead, groupHead } from "./support/cloud.ts"

/**
 * The agent turn cap is a loop guard between agents: it applies only where two or more agents
 * share a conversation. The person's own Chief chat (one person, one Chief) has no cap and keeps
 * the 2 s gap (2026-11-20: the cap refused 25 Chief status messages in a row there).
 */
const send = (host: CoreHost, actor: string, key: string) =>
  host.run(actor, key, { kind: "message.send", client_msg_id: key, parts: [text(key)] })
const code = (r: ReturnType<typeof send>) => (r.ok ? "commit" : r.code)

const local = (...agents: Array<string>) => {
  const r = create({ id: "conv_TEST", actor: "user_local", title: "mux", participants: [human("user_local"), ...agents.map((id) => agent(id))], now: NOW })
  if (!r.ok) throw new Error(r.code)
  return new CoreHost(r.head)
}

describe("agent turn cap: only between agents", () => {
  for (const [name, make, person, chief] of [
    ["local Chief chat", () => local("agent_mux"), "user_local", "agent_mux"],
    ["cloud Chief chat", () => new CoreHost(chiefHead()), ALICE, CHIEF],
    ["cloud group with one Chief", () => new CoreHost(groupHead()), BOB, CHIEF]
  ] as const) {
    it(`${name}: a lone Chief posts past the cap and still waits the gap`, () => {
      const host = make()
      send(host, person, "h1")
      for (let turn = 0; turn < MAX_AGENT_TURNS * 3; turn++) {
        host.advance(MIN_AGENT_GAP_MS)
        expect(code(send(host, chief, `c${turn}`))).toBe("commit")
      }
      host.advance(MIN_AGENT_GAP_MS - 1)
      expect(code(send(host, chief, "soon"))).toBe("agent_rate")
    })
  }

  for (const [name, make, person, a, b] of [
    ["local head with two agents", () => local("agent_a", "agent_b"), "user_local", "agent_a", "agent_b"],
    ["cloud group with two Chiefs", () => new CoreHost(groupHead({ participants: [human(ALICE, "Alice"), human(BOB, "Bob"), agent(CHIEF, ALICE), agent("agent_bobchief", BOB)] })), BOB, CHIEF, "agent_bobchief"]
  ] as const) {
    it(`${name}: the cap still stops the loop`, () => {
      const host = make()
      send(host, person, "h1")
      for (let turn = 0; turn < MAX_AGENT_TURNS; turn++) {
        host.advance(MIN_AGENT_GAP_MS)
        expect(code(send(host, turn % 2 === 0 ? a : b, `c${turn}`))).toBe("commit")
      }
      host.advance(MIN_AGENT_GAP_MS)
      expect(code(send(host, a, "over"))).toBe("agent_budget")
    })
  }

  it("the row-window check agrees: a lone agent is not capped", () => {
    const host = local("agent_mux")
    send(host, "user_local", "h1")
    for (let turn = 0; turn < MAX_AGENT_TURNS; turn++) {
      host.advance(MIN_AGENT_GAP_MS)
      send(host, "agent_mux", `c${turn}`)
    }
    const recent = [...host.messages].reverse()
    const later = Date.parse(host.now) + MIN_AGENT_GAP_MS
    expect(checkAgentBudget(host.head, "agent_mux", [text("more")], recent, later)).toBeNull()
  })
})
