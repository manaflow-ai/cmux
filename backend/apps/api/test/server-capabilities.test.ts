import { describe, expect, it } from "vitest"
import { beginPairing, op, read, sessionToken } from "./pairing-harness.ts"

/**
 * A server names what it is in its pairing request (`info.capabilities`): the approver's
 * preview shows it, and the install that approval registers keeps it, so an app can tell
 * a Chief brain from a plain server without guessing from a version string.
 */
describe("server capabilities", () => {
  it("shows a server's capabilities in the preview and stores them on the paired install", async () => {
    const owner = await sessionToken("stack-cap-owner")
    await op(owner, "user.ensure", {})
    const { res } = await beginPairing(Date.now(), false, "10.0.0.41", undefined, { capabilities: ["optchat-chief-brain"] })
    expect(res.status).toBe(200)
    const code = res.json.code as string
    const preview = await read(owner, "server.pair.preview", { code })
    expect(preview.json.value.info.capabilities).toEqual(["optchat-chief-brain"])
    const team = (await read(owner, "team.directory", {})).json.value.team as string
    const approved = await op(owner, "server.pair.approve", { code, team, name: "cmux-lawrence" })
    expect(approved.json.ok).toBe(true)
    const installs = (await read(owner, "install.list", {})).json.value
    expect(installs.installs.find((i: any) => i.id === approved.json.value.install).capabilities).toEqual(["optchat-chief-brain"])
  })

  it("keeps a server without capabilities as before and refuses malformed ones", async () => {
    const owner = await sessionToken("stack-cap-plain")
    await op(owner, "user.ensure", {})
    const plain = await beginPairing(Date.now(), false, "10.0.0.42")
    const preview = await read(owner, "server.pair.preview", { code: plain.res.json.code })
    expect(preview.json.value.info.capabilities).toBeUndefined()
    const bad = await beginPairing(Date.now(), false, "10.0.0.43", undefined, { capabilities: ["Not A Capability!"] })
    expect(bad.res.status).toBe(400)
  })
})
