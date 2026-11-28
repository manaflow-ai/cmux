import type { Principal } from "@cmux/ownership"
import { beforeEach, describe, expect, it, vi } from "vitest"
import type { Env } from "../src/env.ts"

// Each search reader opens a fresh connection when its first one is lost, closes the lost one, and answers the
// second's rows (lost-connection.ts). A timeout is not resent.

const row = { conversation_id: "conv_1", title: "t", seq: 3, message_id: "m_1", author_id: "user_aaaaaaaaaaaaaaaaaaaa", created_at: "2026-11-28T14:23:00.000Z", body: "hello world" }
const principal: Principal = { identity: "session:user_aaaaaaaaaaaaaaaaaaaa", kind: "session", user: "user_aaaaaaaaaaaaaaaaaaaa", team: "team_aaaaaaaaaaaaaaaaaaaa" }

interface FakeClient {
  readonly id: number
  closed: boolean
}

// Each opened client answers the next scripted answer: an Error fails its query, anything else is its rows.
const fake = vi.hoisted(() => ({ answers: [] as Array<unknown>, clients: [] as Array<{ id: number; closed: boolean }> }))
const nextAnswer = async () => {
  const answer = fake.answers.shift()
  if (answer instanceof Error) throw answer
  return answer
}

vi.mock("../src/mysql-connect.ts", () => ({
  connectMysql: vi.fn(async () => {
    const client: FakeClient = { id: fake.clients.length + 1, closed: false }
    fake.clients.push(client)
    return {
      query: async () => [await nextAnswer()],
      end: async () => {
        client.closed = true
      },
      destroy: () => {
        client.closed = true
      }
    }
  })
}))

vi.mock("pg", () => ({
  default: {
    Client: class {
      readonly me: FakeClient
      constructor() {
        this.me = { id: fake.clients.length + 1, closed: false }
        fake.clients.push(this.me)
      }
      async connect() {}
      async query() {
        return { rows: await nextAnswer() }
      }
      async end() {
        this.me.closed = true
      }
    }
  }
}))

const lostMysql = Object.assign(new Error("Connection lost: The server closed the connection."), { code: "PROTOCOL_CONNECTION_LOST" })
const lostPg = new Error("Connection terminated unexpectedly")

const search = async (reader: "mysql" | "postgres") => {
  const { homeSearch } = await import("../src/home-search.ts")
  const target = { host: "mysql.test", port: 3306, user: "u", password: "p", database: "d" }
  const env = (reader === "mysql" ? { PROJECTION_READS: "mysql", PS_MYSQL_RO: target } : { PROJECTION_READS: "postgres", HYPERDRIVE_RO: { connectionString: "postgres://ro.test/db" } }) as unknown as Env
  return homeSearch(env, principal, { q: "hello" })
}

beforeEach(() => {
  fake.answers.length = 0
  fake.clients.length = 0
})

describe.each([
  ["mysql", lostMysql, Object.assign(new Error("connect ETIMEDOUT"), { code: "ETIMEDOUT" })],
  ["postgres", lostPg, new Error("Connection terminated due to connection timeout")]
] as const)("home.search on %s", (reader, lost, timeout) => {
  it("answers from a second, fresh connection when the first is lost", async () => {
    fake.answers.push(lost, [row])
    const result = await search(reader)
    expect(result.ok).toBe(true)
    expect(result.ok && result.value.hits.map((h) => h.conversation)).toEqual(["conv_1"])
    expect(fake.clients.map((c) => c.id)).toEqual([1, 2])
    expect(fake.clients.every((c) => c.closed)).toBe(true)
  })

  it("does not resend after a timeout", async () => {
    fake.answers.push(timeout, [row])
    const result = await search(reader)
    expect(result).toMatchObject({ ok: false, code: "search.unavailable" })
    expect(fake.clients.length).toBe(1)
  })
})
