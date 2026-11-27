import { describe, expect, it } from "vitest"
import { openCloudWorkspace, workspaceNote, type WorkspaceHands } from "../src/chief-brain/brain-spawn-workspace.ts"

/** A hand port: records the exec calls and answers with what `cmux workspace create --json` prints. */
const port = (hands: ReadonlyArray<{ hand: string; name: string; online: boolean; sandbox?: boolean }>, stdout: string, exitCode = 0) => {
  const calls: Array<{ hand: string; argv: ReadonlyArray<string> }> = []
  const p: WorkspaceHands = {
    list: async () => hands,
    exec: async (hand, argv) => (calls.push({ hand, argv }), { exitCode, stdout, stderr: exitCode ? "boom" : "" })
  }
  return { p, calls }
}

describe("a Cloud Chief's spawned child gets a cloud workspace on the Chief's VM", () => {
  it("makes the workspace on the online sandbox hand and returns its id", async () => {
    const { p, calls } = port([{ hand: "h_mac", name: "mac", online: true }, { hand: "h_sb", name: "sb-1", online: true, sandbox: true }], '{"workspace":{"id":"ws_abc123"}}')
    const r = await openCloudWorkspace(p, "Fix the login bug")
    expect(r).toEqual({ ok: true, ws: "ws_abc123", machine: "sb-1" })
    expect(calls).toHaveLength(1)
    expect(calls[0]!.hand).toBe("h_sb")
    expect(calls[0]!.argv).toEqual(expect.arrayContaining(["workspace", "create", "--name", "Fix the login bug"]))
  })
  it("says why when the Chief has no online sandbox hand", async () => {
    const { p, calls } = port([{ hand: "h_sb", name: "sb-1", online: false, sandbox: true }], "")
    const r = await openCloudWorkspace(p, "x")
    expect(r.ok).toBe(false)
    expect(calls).toHaveLength(0)
    expect(workspaceNote(r)).toMatch(/no workspace/i)
  })
  it("says why when the create fails or prints no id", async () => {
    const bad = await openCloudWorkspace(port([{ hand: "h", name: "sb", online: true, sandbox: true }], "", 1).p, "x")
    expect(bad.ok).toBe(false)
    const none = await openCloudWorkspace(port([{ hand: "h", name: "sb", online: true, sandbox: true }], "created").p, "x")
    expect(none.ok).toBe(false)
  })
  it("links the workspace in the note, never the bare id", async () => {
    expect(workspaceNote({ ok: true, ws: "ws_abc123", machine: "sb-1" })).toBe("[workspace](cmux://workspace/ws_abc123) on sb-1")
  })
})
