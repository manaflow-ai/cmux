import type { ChiefBrainDO } from "../chief-brain/brain-do.ts"
import { writeConfig } from "../chief-brain/brain-store.ts"
import { CcError, freestyle } from "./vm.ts"

/**
 * Files and snapshots of the Chief's sandboxes (plans/cmux-next/chief-vm-freestyle-parity.md batch 3;
 * freestyle.sh/docs/vms/files, lifecycle, CLI). Called by sandbox.ts after its owner check, with the team key
 * (Freestyle's identity tokens reach only exec and terminals). Reads work on a paused or stopped VM without
 * waking it; writes wake it. The turn machine's runner takes at most 200 kB a call, so file data moves in
 * base64 chunks of at most CHUNK bytes: `read` takes an offset and length, `write` writes a small file whole,
 * and `upload_*` is Freestyle's resumable upload (to 16 GiB) a chunk at a time.
 *
 * Snapshots: only the ones this Chief took (cb_config `cc_snapshots`) are reachable; each is kept SNAP_TTL_S by
 * default. `fork` is a snapshot of a running VM (under 1 ms of pause) and a new sandbox from it.
 */
export const CHUNK = 128 * 1024
const SNAP_TTL_S = 7 * 86_400
type Out = { status: number; json: unknown }
type Req = Record<string, unknown>
export type Snap = { id: string; name: string | null; source: string; created_at: number }

const pathOf = (req: Req): string | null => (typeof req.path === "string" && req.path.startsWith("/") && req.path.length <= 4096 && !req.path.includes("\0") ? req.path : null)
const BAD_PATH: Out = { status: 400, json: { error: "path must be absolute" } }
const fail = async (what: string, res: Response): Promise<Out> => {
  const m = ((await res.json().catch(() => null)) as { message?: unknown } | null)?.message
  return { status: res.status === 404 ? 404 : res.status === 400 || res.status === 409 || res.status === 429 ? res.status : 502, json: { error: `${what} (${res.status})${typeof m === "string" ? `: ${m.slice(0, 300)}` : ""}` } }
}
const b64 = (bytes: Uint8Array) => {
  let s = ""
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}
const unb64 = (s: string): Uint8Array | null => {
  try {
    return Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
  } catch {
    return null
  }
}
const q = (path: string, extra: Record<string, string> = {}) => `?${new URLSearchParams({ path, ...extra })}`

/** The fs verbs: read, write, ls, mkdir, stat, rm, exists, upload_begin, upload_chunk, upload_status, upload_commit, upload_abort. */
export const fileVerb = async (b: ChiefBrainDO, vm: string, verb: string, req: Req): Promise<Out> => {
  const env = b.doEnv
  const at = `/v5/vms/${encodeURIComponent(vm)}/fs`
  if (verb.startsWith("upload_") && verb !== "upload_begin") {
    const up = typeof req.upload_id === "string" && /^[A-Za-z0-9_-]{1,128}$/.test(req.upload_id) ? req.upload_id : null
    if (!up) return { status: 400, json: { error: "upload_id is missing" } }
    const u = `${at}/uploads/${encodeURIComponent(up)}`
    if (verb === "upload_chunk") {
      const off = Number(req.offset)
      const bytes = typeof req.data === "string" ? unb64(req.data) : null
      if (!Number.isInteger(off) || off < 0 || !bytes || bytes.length === 0 || bytes.length > CHUNK) return { status: 400, json: { error: `a chunk is base64 data of 1 to ${CHUNK} bytes at a whole offset` } }
      const res = await fetchRaw(b, "PUT", `${u}?offset=${off}`, bytes)
      return res.ok ? { status: 200, json: { upload: await res.json().catch(() => null) } } : fail("chunk not taken", res)
    }
    const res = await freestyle(env, verb === "upload_status" ? "GET" : verb === "upload_commit" ? "POST" : "DELETE", verb === "upload_commit" ? `${u}/commit` : u, verb === "upload_commit" ? {} : undefined, 120_000)
    if (!res.ok) return fail(`${verb.slice(7)} failed`, res)
    return { status: 200, json: verb === "upload_status" ? { upload: await res.json().catch(() => null) } : (await res.body?.cancel().catch(() => undefined), { ok: true }) }
  }
  const path = pathOf(req)
  if (!path) return BAD_PATH
  switch (verb) {
    case "read": {
      const offset = Math.max(0, Number(req.offset) || 0)
      const length = Math.min(CHUNK, Math.max(1, Number(req.length) || CHUNK))
      const res = await freestyle(env, "GET", `${at}/read${q(path)}`, undefined, 60_000, { range: `bytes=${offset}-${offset + length - 1}` })
      if (res.status === 416) return void (await res.body?.cancel().catch(() => undefined)), { status: 200, json: { data: "", bytes: 0, offset, eof: true } }
      if (!res.ok) return fail("not read", res)
      const bytes = new Uint8Array(await res.arrayBuffer())
      const total = Number(/\/(\d+)$/.exec(res.headers.get("content-range") ?? "")?.[1] ?? NaN)
      const all = bytes.length > length ? bytes.subarray(offset, offset + length) : bytes
      const size = Number.isFinite(total) ? total : res.status === 200 ? bytes.length : null
      return { status: 200, json: { data: b64(all), bytes: all.length, offset, size, eof: size !== null ? offset + all.length >= size : all.length < length } }
    }
    case "write": {
      const bytes = typeof req.data === "string" ? unb64(req.data) : null
      if (!bytes || bytes.length > CHUNK) return { status: 400, json: { error: `write takes base64 data of at most ${CHUNK} bytes (larger files: upload_begin)` } }
      const mode = req.mode === undefined ? undefined : Number(req.mode)
      if (mode !== undefined && (!Number.isInteger(mode) || mode < 0 || mode > 0o7777)) return { status: 400, json: { error: "mode must be octal permission bits" } }
      const res = await freestyle(env, "PUT", `${at}/write`, { path, content: b64(bytes), encoding: "base64", ...(mode !== undefined ? { mode } : {}) }, 120_000)
      if (!res.ok) return fail("not written", res)
      await res.body?.cancel().catch(() => undefined)
      return { status: 200, json: { path, bytes: bytes.length } }
    }
    case "upload_begin": {
      const size = Number(req.size)
      if (!Number.isInteger(size) || size < 0 || size > 16 * 1024 ** 3) return { status: 400, json: { error: "size must be the file's byte count (at most 16 GiB)" } }
      const sha = typeof req.sha256 === "string" && /^[0-9a-f]{64}$/.test(req.sha256) ? req.sha256 : undefined
      const res = await freestyle(env, "POST", `${at}/uploads`, { path, size, ...(sha ? { sha256: sha } : {}), ...(req.mode !== undefined ? { mode: Number(req.mode) } : {}) }, 60_000)
      return res.ok ? { status: 200, json: { upload: await res.json().catch(() => null), chunk: CHUNK } } : fail("upload not started", res)
    }
    case "ls":
    case "stat":
    case "exists": {
      const res = await freestyle(env, "GET", `${at}/${verb === "ls" ? "dir" : verb}${q(path)}`, undefined, 60_000)
      return res.ok ? { status: 200, json: await res.json().catch(() => null) } : fail(`${verb} failed`, res)
    }
    case "mkdir":
    case "rm": {
      const res = verb === "mkdir" ? await freestyle(env, "POST", `${at}/mkdir`, { path }, 60_000) : await freestyle(env, "DELETE", `${at}/remove${q(path)}`, undefined, 60_000)
      if (!res.ok) return fail(`${verb} failed`, res)
      await res.body?.cancel().catch(() => undefined)
      return { status: 200, json: { ok: true, path } }
    }
  }
  return { status: 400, json: { error: "fs verb must be read, write, ls, mkdir, stat, rm, exists or upload_begin|chunk|status|commit|abort" } }
}

/** A raw-bytes call with the team key (an upload chunk). */
const fetchRaw = async (b: ChiefBrainDO, method: string, path: string, body: Uint8Array): Promise<Response> =>
  await fetch(`${(b.doEnv.CHIEF_CC_FREESTYLE_API_URL || "https://api.freestyle.sh").replace(/\/+$/, "")}${path}`, { method, redirect: "manual", signal: AbortSignal.timeout(120_000), headers: { authorization: `Bearer ${b.doEnv.CHIEF_CC_FREESTYLE_API_KEY}`, "content-type": "application/octet-stream" }, body }).catch((e: unknown) => {
    throw new CcError(`${method} upload chunk: no answer (${String(e).slice(0, 200)})`)
  })

export const snapsOf = (b: ChiefBrainDO): Array<Snap> => {
  const raw = b.sql.exec<{ value: string }>(`SELECT value FROM cb_config WHERE name = 'cc_snapshots'`).toArray()[0]?.value
  try {
    const xs = JSON.parse(raw ?? "[]") as Array<Snap>
    return Array.isArray(xs) ? xs.filter((x) => typeof x?.id === "string") : []
  } catch {
    return []
  }
}
const saveSnaps = (b: ChiefBrainDO, xs: ReadonlyArray<Snap>) => writeConfig(b.sql, { cc_snapshots: JSON.stringify(xs) })
const snapView = (s: Snap, r: Record<string, unknown> | null) => ({ ...s, state: r ? "ready" : "unknown", display_name: typeof r?.displayName === "string" ? r.displayName : s.name, ttl_seconds: typeof r?.ttlSeconds === "number" ? r.ttlSeconds : null, size_bytes: typeof r?.sizeBytes === "number" ? r.sizeBytes : null })

/** Snapshots VM `vm` (memory and disk) and keeps the id as this Chief's. */
export const takeSnapshot = async (b: ChiefBrainDO, vm: string, req: Req): Promise<Out & { snap?: Snap }> => {
  const name = typeof req.name === "string" && req.name.length <= 200 ? req.name : null
  const ttl = req.ttl_seconds === undefined ? SNAP_TTL_S : Number(req.ttl_seconds)
  if (!Number.isInteger(ttl) || ttl < 60 || ttl > 90 * 86_400) return { status: 400, json: { error: "ttl_seconds must be a whole number from 60 to 7776000" } }
  const res = await freestyle(b.doEnv, "POST", `/v5/vms/${encodeURIComponent(vm)}/snapshot`, { ttlSeconds: ttl, ...(name ? { displayName: name } : {}) }, 300_000)
  if (!res.ok) return fail("no snapshot", res)
  const body = (await res.json().catch(() => null)) as { snapshotId?: unknown } | null
  if (typeof body?.snapshotId !== "string") return { status: 502, json: { error: "Freestyle did not name the snapshot" } }
  const snap: Snap = { id: body.snapshotId, name, source: vm, created_at: Date.now() }
  saveSnaps(b, [...snapsOf(b), snap])
  return { status: 200, json: { snapshot: { ...snap, ttl_seconds: ttl } }, snap }
}

/** snapshots, snapshot_get, snapshot_rename, snapshot_delete on this Chief's own snapshots. */
export const snapshotVerb = async (b: ChiefBrainDO, verb: string, req: Req): Promise<Out> => {
  const env = b.doEnv
  if (verb === "snapshots") {
    const out: Array<ReturnType<typeof snapView>> = []
    const kept: Array<Snap> = []
    for (const s of snapsOf(b)) {
      const res = await freestyle(env, "GET", `/v5/snapshots/${encodeURIComponent(s.id)}`, undefined, 10_000).catch(() => null)
      if (res?.status === 404) {
        await res.body?.cancel().catch(() => undefined)
        continue
      }
      kept.push(s)
      out.push(snapView(s, res?.ok ? ((await res.json().catch(() => null)) as Record<string, unknown> | null) : null))
    }
    saveSnaps(b, kept)
    return { status: 200, json: { snapshots: out } }
  }
  const s = snapsOf(b).find((x) => x.id === req.snapshot)
  if (!s) return { status: 404, json: { error: "not one of your snapshots (chief-vm snapshots)" } }
  const at = `/v5/snapshots/${encodeURIComponent(s.id)}`
  if (verb === "snapshot_get") {
    const res = await freestyle(env, "GET", at, undefined, 10_000)
    return res.ok ? { status: 200, json: { snapshot: snapView(s, (await res.json().catch(() => null)) as Record<string, unknown> | null) } } : fail("not found", res)
  }
  if (verb === "snapshot_rename") {
    if (typeof req.name !== "string" || !req.name || req.name.length > 200) return { status: 400, json: { error: "name must be text (at most 200 characters)" } }
    const res = await freestyle(env, "PATCH", at, { displayName: req.name })
    if (!res.ok) return fail("not renamed", res)
    await res.body?.cancel().catch(() => undefined)
    saveSnaps(b, snapsOf(b).map((x) => (x.id === s.id ? { ...x, name: req.name as string } : x)))
    return { status: 200, json: { snapshot: { ...s, name: req.name } } }
  }
  if (verb === "snapshot_delete") {
    const res = await freestyle(env, "DELETE", at)
    if (!res.ok && res.status !== 404) return fail("not deleted", res)
    await res.body?.cancel().catch(() => undefined)
    saveSnaps(b, snapsOf(b).filter((x) => x.id !== s.id))
    return { status: 200, json: { deleted: s.id } }
  }
  return { status: 400, json: { error: "snapshot verb must be snapshots, snapshot_get, snapshot_rename or snapshot_delete" } }
}
