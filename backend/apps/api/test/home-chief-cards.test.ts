/**
 * Chief cards (https://github.com/manaflow-ai/cmux/issues/25830): a `card` part is posted by the Chief only, its
 * browser screenshot is an attachment record of the conversation (checked like a link preview's image), and the
 * Chief edits its browser card in place as steps change.
 */
import { decodeJwt } from "jose"
import { describe, expect, it } from "vitest"

import { formatMessage } from "../src/chief-brain/brain-text.ts"
import { fireAlarm } from "./setup/alarm.ts"
import { op, post, sessionToken, sha, testEnv, worker } from "./home-attachments-support.ts"

const b64u = (b: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(b))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
const PNG = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, ...new TextEncoder().encode(" a browser screenshot")])

/** A signed-in owner with an install that mints Chief tokens (as in chief-token.test.ts). */
const ownerWithChief = async (sub: string) => {
  const session = await sessionToken(sub)
  const user = (await op(session, "user.ensure", {})).json.value.id as string
  const pair = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"])) as CryptoKeyPair
  const jwk = (await crypto.subtle.exportKey("jwk", pair.publicKey)) as JsonWebKey
  const install = (await op(session, "install.register", { public_jwk: { kty: "EC", crv: "P-256", x: jwk.x!, y: jwk.y! }, kind: "mac", name: "mac", device_name: "mac", platform: "macos" })).json.value.id as string
  const chief = (await op(session, "chief.create", { display_name: "Chief" })).json.value
  const ch = await post("/v1/auth/challenge", undefined, { user, install })
  const sig = await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, pair.privateKey, new TextEncoder().encode(`${ch.json.message_prefix}${ch.json.nonce}`))
  const tok = (await post("/v1/auth/token", undefined, { user, install, nonce: ch.json.nonce, signature: b64u(sig), agent: chief.id })).json.access_token as string
  expect(decodeJwt(tok)).toMatchObject({ agt: chief.id })
  const conversation = chief.main_conversation as string
  const userDO = testEnv.USER_DO.get(testEnv.USER_DO.idFromName(user))
  for (let i = 0; i < 20 && (await post("/v1/read", session, { op: "conversation.history", params: { conversation, limit: 1 } })).status !== 200; i++) await fireAlarm(userDO)
  return { session, tok, conversation }
}

describe("Home: Chief cards", { timeout: 120_000 }, () => {
  it("only the Chief posts a card; a browser card's screenshot must be its upload; the Chief edits the card live", async () => {
    const { session, tok, conversation } = await ownerWithChief("chief-cards-a")
    const send = (token: string, parts: unknown, key: string) => op(token, "message.send", { conversation, client_msg_id: key, parts }, key)
    const shot = { hash: sha(PNG), mime_type: "image/png", byte_count: PNG.byteLength, width: 1280, height: 800 }
    const browser = (over: Record<string, unknown> = {}) => ({ type: "card", kind: "browser", surface: "browser", step: "Opening LinkedIn", live: true, target: "browser:right", url: "https://www.linkedin.com/messaging/", ...over })

    // The person cannot post a card; an unknown kind is refused for everyone.
    expect((await send(session, [{ type: "card", kind: "next_steps", choices: ["Yes"] }], "p0")).json.error.code).toBe("invalid_parts")
    expect((await send(tok, [{ type: "card", kind: "map" }], "c0")).json.error.code).toBe("invalid_parts")
    // The screenshot is checked against this conversation's records.
    expect((await send(tok, [browser({ image: shot })], "c1")).json.error.code).toBe("unknown_attachment")
    const intent = await post("/v1/home/attachments/intent", tok, { conversation, sha256: shot.hash, byte_count: shot.byte_count, mime_type: "image/png", name: "browser.png", width: 1280, height: 800 })
    expect(intent.json.ok, JSON.stringify(intent.json)).toBe(true)
    if (intent.json.value.state === "upload") expect((await worker.fetch(intent.json.value.upload_url, { method: "PUT", body: PNG, headers: { "content-length": String(PNG.byteLength) } })).status).toBe(200)
    expect((await send(tok, [browser({ image: { ...shot, mime_type: "image/webp" } })], "c2")).json.error.code).toBe("attachment_mismatch")

    const sent = await send(tok, [browser({ image: shot })], "c3")
    expect(sent.json.ok, JSON.stringify(sent.json)).toBe(true)
    const messageId = sent.json.value.message_id as string
    // The owner reads the screenshot by the card part.
    const minted = await post("/v1/home/attachments/url", session, { conversation, hash: shot.hash, message_id: messageId, part_index: 0 })
    expect(minted.status, JSON.stringify(minted.json)).toBe(200)
    const res = await worker.fetch(minted.json.value.url)
    expect(res.headers.get("content-type")).toBe("image/png")
    expect(new Uint8Array(await res.arrayBuffer())).toEqual(PNG)

    // The Chief edits the card as the step changes; then a reply with next steps and a sign-in card.
    const edited = await op(tok, "message.edit", { conversation, message_id: messageId, parts: [browser({ step: "Sent the message", live: false, image: shot })] })
    expect(edited.json.ok, JSON.stringify(edited.json)).toBe(true)
    const reply = await send(tok, [{ type: "text", text: "Sent." }, { type: "card", kind: "sign_in", site: "linkedin.com" }, { type: "card", kind: "next_steps", choices: ["Check for a reply", "Stop"] }], "c4")
    expect(reply.json.ok, JSON.stringify(reply.json)).toBe(true)
    const hist = await post("/v1/read", session, { op: "conversation.history", params: { conversation, limit: 5 } })
    const parts = (hist.json.value.messages as Array<{ id: string; parts: Array<Record<string, unknown>> }>).find((m) => m.id === messageId)!.parts
    expect(parts).toEqual([browser({ step: "Sent the message", live: false, image: shot })])
  })

  it("the Chief reads a card as its text fallback", () => {
    const head = { id: "conv_x", kind: "chief", title: "", participants: [{ id: "agent_c", display_name: "Chief", kind: "agent" }] } as never
    const parts = [
      { type: "card", kind: "browser", surface: "computer", step: "Opening Mail", live: true },
      { type: "card", kind: "sign_in", site: "linkedin.com" },
      { type: "card", kind: "next_steps", choices: ["Retry", "Stop"] }
    ]
    expect(formatMessage(head, { id: "msg_1", seq: 1, author: "agent_c", parts } as never)).toBe(
      "[chief · chief · Chief] [card: Computer: Opening Mail]\n[card: Secure Store: sign in to linkedin.com]\n[card: → Retry\n→ Stop]"
    )
  })
})
