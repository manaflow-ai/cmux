import type { Env } from "../env.ts"
import { brainName } from "../chief-brain/brain-do.ts"
import { CC_NOTES_PATH, notesTokenOk } from "./turn.ts"
import { ccConfigured } from "./vm.ts"

export { CC_NOTES_PATH }

/** At most this much JSON per notes post (the turn machine sends batches of at most 200 events). */
const MAX_BODY = 1_000_000

/**
 * POST /v1/chief-cc/<agent>/<conversation>/notes: a turn machine's stream and result (chief-brain-cc/turn.ts).
 * The bearer is the token made for the running turn only: its mac is checked here, before any object wakes
 * (an unauthenticated post never creates a brain), and the conversation brain checks that it is the running
 * turn's. 404 where the route is off, 401 for any other token, 413 above MAX_BODY (refused before it is read).
 * A body with `net` is the Chief's network change (net.ts): JSON back, the settings and the script, or 400.
 * A body with `vm` is the Chief's sandbox call (sandbox.ts): JSON back.
 */
export const handleCcNotes = async (request: Request, env: Env, agent: string, conversation: string): Promise<Response> => {
  if (!ccConfigured(env) || request.method !== "POST") return new Response("not found", { status: 404 })
  const token = (request.headers.get("authorization") ?? "").replace(/^Bearer\s+/i, "")
  if (!token) return new Response("unauthorized", { status: 401 })
  if (Number(request.headers.get("content-length") ?? 0) > MAX_BODY) return new Response("too large", { status: 413 })
  const text = await readCapped(request, MAX_BODY)
  if (text === null) return new Response("too large", { status: 413 })
  let body: { run?: unknown; events?: unknown; result?: unknown; net?: unknown; vm?: unknown }
  try {
    body = JSON.parse(text) as typeof body
  } catch {
    return new Response("bad json", { status: 400 })
  }
  if (!(await notesTokenOk(env, agent, conversation, typeof body?.run === "string" ? body.run : "", token))) return new Response("unauthorized", { status: 401 })
  const brain = env.CHIEF_BRAIN_DO.get(env.CHIEF_BRAIN_DO.idFromName(brainName(agent, conversation))) as unknown as { ccNotes(t: string, b: unknown): Promise<{ status: number; json?: unknown }> }
  const r = await brain.ccNotes(token, body)
  if (r.json !== undefined) return Response.json(r.json, { status: r.status })
  return new Response(r.status === 200 ? "ok" : "unauthorized", { status: r.status })
}

/** The body as text, or null once it passes `max` bytes (it stops reading there). */
const readCapped = async (request: Request, max: number): Promise<string | null> => {
  if (!request.body) return ""
  const reader = request.body.getReader()
  const parts: Array<Uint8Array> = []
  let n = 0
  for (;;) {
    const { done, value } = await reader.read()
    if (done) break
    n += value.byteLength
    if (n > max) {
      await reader.cancel().catch(() => undefined)
      return null
    }
    parts.push(value)
  }
  const all = new Uint8Array(n)
  let at = 0
  for (const p of parts) [all.set(p, at), (at += p.byteLength)]
  return new TextDecoder().decode(all)
}
