import { describe, expect, it, vi } from "vitest"

// A connection whose session setup fails: connectMysql must close it, because the caller never gets a client.
const conn = vi.hoisted(() => ({
  query: vi.fn(async () => {
    throw new Error("setup refused")
  }),
  end: vi.fn(async () => {}),
  destroy: vi.fn()
}))

vi.mock("mysql2/promise", () => ({ createConnection: vi.fn(async () => conn) }))

describe("connectMysql", () => {
  it("destroys the connection when the session setup query fails", async () => {
    const { connectMysql } = await import("../src/mysql-connect.ts")
    await expect(
      connectMysql({ host: "mysql.test", port: 3306, user: "u", password: "p", database: "d" })
    ).rejects.toThrow("setup refused")
    expect(conn.query).toHaveBeenCalledWith("SET time_zone = '+00:00'")
    expect(conn.destroy).toHaveBeenCalledTimes(1)
  })
})
