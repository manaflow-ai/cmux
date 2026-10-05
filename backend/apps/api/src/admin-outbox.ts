import type { Env } from "./env.ts"
import { timingSafeEqual } from "./ingress/verify.ts"

/**
 * Operator replay tool for dead outbox items (home-scale review P1).
 * `POST /v1/admin/outbox/replay` with `authorization: Bearer <OUTBOX_ADMIN_KEY>` and the body
 * `{"class": "ConversationDO", "name": "<object name>", "ids"?: [n, ...]}`. The route does not
 * exist (404) when the secret is not set. Delivery is idempotent, so a replay never applies an
 * item twice. OwnerDO also replays dead items by itself once a day.
 */
const OWNER_CLASSES = ["UserDO", "TeamDO", "SchedulerDO", "ConnectionDO", "FeedDO", "ConversationDO", "MuxDO", "AddressDO", "TeamVmDO", "UsageMeterDO", "CloudDO"] as const
const bindingOf = (cls: string) => cls.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toUpperCase()

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json", "cache-control": "no-store" } })

export const handleOutboxReplay = async (request: Request, env: Env): Promise<Response> => {
  const key = env.OUTBOX_ADMIN_KEY
  if (!key || key.length < 32) return json({ error: "not found" }, 404)
  if (request.method !== "POST") return json({ error: "method not allowed" }, 405)
  const presented = (request.headers.get("authorization") ?? "").replace(/^Bearer /, "")
  if (!timingSafeEqual(presented, key)) return json({ error: "unauthorized" }, 401)
  if (Number(request.headers.get("content-length") ?? "0") > 64 * 1024) return json({ error: "body too large" }, 413)
  const raw = await request.text()
  if (raw.length > 64 * 1024) return json({ error: "body too large" }, 413)
  const body = (() => {
    try {
      return JSON.parse(raw) as { class?: unknown; name?: unknown; ids?: unknown } | null
    } catch {
      return null
    }
  })()
  const cls = typeof body?.class === "string" && (OWNER_CLASSES as ReadonlyArray<string>).includes(body.class) ? body.class : null
  const name = typeof body?.name === "string" && body.name.length > 0 && body.name.length <= 200 ? body.name : null
  const ids = body?.ids === undefined ? undefined : Array.isArray(body.ids) && body.ids.length <= 1000 && body.ids.every((n) => Number.isInteger(n)) ? (body.ids as Array<number>) : null
  if (!cls || !name || ids === null) return json({ error: "class (an owner class), name and optional integer ids are required" }, 400)
  const ns = (env as unknown as Record<string, DurableObjectNamespace | undefined>)[bindingOf(cls)]
  if (!ns) return json({ error: `no binding for ${cls}` }, 400)
  const stub = ns.get(ns.idFromName(name)) as unknown as { replayDeadLetters(entity: string, ids?: ReadonlyArray<number>): Promise<{ replayed: number; dead: number }> }
  const r = await stub.replayDeadLetters(name, ids).catch(() => null)
  if (!r) return json({ error: "replay failed (the name may belong to another object)" }, 400)
  console.warn(JSON.stringify({ msg: "outbox replay (operator)", class: cls, replayed: r.replayed, dead: r.dead }))
  return json(r)
}
