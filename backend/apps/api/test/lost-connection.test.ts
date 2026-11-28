import { describe, expect, it } from "vitest"
import { connectionLost, readResendingOnLostConnection } from "../src/lost-connection.ts"

// A per-call read whose connection drops is sent once more on a fresh connection (lost-connection.ts).
describe("readResendingOnLostConnection", () => {
  it("resends once after a lost connection", async () => {
    const answers: Array<unknown> = [Object.assign(new Error("Connection lost: The server closed the connection."), { code: "PROTOCOL_CONNECTION_LOST" }), ["row"]]
    let calls = 0
    const rows = await readResendingOnLostConnection(async () => {
      calls += 1
      const next = answers.shift()
      if (next instanceof Error) throw next
      return next
    })
    expect(rows).toEqual(["row"])
    expect(calls).toBe(2)
  })

  it("gives up after one resend", async () => {
    let calls = 0
    await expect(
      readResendingOnLostConnection(async () => {
        calls += 1
        throw new Error("Network connection lost.")
      })
    ).rejects.toThrow("Network connection lost.")
    expect(calls).toBe(2)
  })

  it("does not resend a statement error", async () => {
    let calls = 0
    await expect(
      readResendingOnLostConnection(async () => {
        calls += 1
        throw Object.assign(new Error("Query execution was interrupted"), { code: "ER_QUERY_TIMEOUT" })
      })
    ).rejects.toThrow("interrupted")
    expect(calls).toBe(1)
  })

  it("tells a lost connection from other failures", () => {
    expect(connectionLost(new Error("Connection terminated unexpectedly"))).toBe(true)
    expect(connectionLost(Object.assign(new Error("read"), { code: "ECONNRESET" }))).toBe(true)
    expect(connectionLost(Object.assign(new Error("duplicate"), { code: "23505" }))).toBe(false)
    expect(connectionLost("Network connection lost.")).toBe(false)
  })
})

describe("connectionLost and timeouts", () => {
  it("never calls a timeout lost", () => {
    // mysql2's connect timeout (connectMysql's 5 s), pg's connect and query timeouts.
    expect(connectionLost(Object.assign(new Error("connect ETIMEDOUT"), { code: "ETIMEDOUT" }))).toBe(false)
    expect(connectionLost(new Error("Connection terminated due to connection timeout"))).toBe(false)
    expect(connectionLost(new Error("Query read timeout"))).toBe(false)
  })
})
