import { expect } from "vitest"
import { parseEnrollArgs, bindMessage } from "../src/team-vm-bind.ts"
import { instanceFingerprint } from "../../../../libs/vm-instance-identity/src/identity.ts"

const b64u = (bytes: ArrayBuffer) => btoa(String.fromCharCode(...new Uint8Array(bytes))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
interface Machine {
  id: string; displayName: string; labels: Record<string, string>; state: string; instance: string
  key: CryptoKeyPair; present: boolean; retired: boolean; install: string | null
  image: { id: string; revision: string }; actor: string
}

/** Fake only the HTTP service; owner records, reducers, binding, export and grants remain real. */
export const teamVmApiService = (tenant: string) => {
  const vms = new Map<string, Machine>(), intents = new Map<string, { body: string; id: string }>()
  const calls: Array<{ method: string; path: string; body: Record<string, any> | null; key: string | null }> = []
  // The real API answers a repeated DELETE of the caller's own deleted VM with 204 (workers/cmux-vm handlers/vms.ts).
  const tombstones = new Set<string>()
  const control = { creationState: "missing" as "missing" | "pending" | "committed" | "cancelling" | "cancelled", loseNextDelete: false, loseNextCreate: false, forbidden: false, actor: "team-vm-service", key: "team-transport-test-key", creates: 0, fileReads: 0, breakNextFileRead: false, fileOffsets: [] as number[] }
  const bodyOf = (m: Machine) => ({ id: m.id, displayName: m.displayName, labels: m.labels, state: m.state,
    resources: { vcpus: 4, memoryMib: 8192, diskMib: 32768 }, idleTimeoutSeconds: -1,
    maxRunSeconds: null, autoDeleteSeconds: null, createdAt: "2026-10-01T00:00:00Z", updatedAt: "2026-10-01T00:00:00Z" })
  const notFound = () => Response.json({ _tag: "NotFound", message: "VM not found" }, { status: 404 })
  const fetchFn: typeof fetch = async (input, init) => {
    const r = new Request(input, init), u = new URL(r.url)
    expect(u.origin).toBe("https://vm.test")
    expect(r.headers.get("authorization")).toBe(`Bearer ${control.key}`)
    expect(r.headers.get("x-cmux-team-id")).toBe(tenant)
    expect(r.redirect).toBe("manual")
    const body = r.body ? await r.clone().json() as Record<string, any> : null
    const key = r.headers.get("idempotency-key")
    calls.push({ method: r.method, path: u.pathname, body, key })
    if (u.pathname.startsWith("/v1/vm-creations/by-key")) {
      const intent = key ? intents.get(key) : undefined, m = intent ? vms.get(intent.id) : undefined
      if (control.creationState === "missing" || control.forbidden || !m || m.actor !== control.actor) return notFound()
      if (r.method === "POST" && control.creationState === "pending") control.creationState = "committed"
      return Response.json({ state: control.creationState === "cancelling" ? "pending" : control.creationState === "cancelled" ? "deleted" : control.creationState,
        ...(control.creationState === "cancelling" ? { cancellation: "requested" } : control.creationState === "cancelled" ? { cancellation: "completed" } : {}), id: m.id, receipt: { id: m.id, displayName: m.displayName, labels: m.labels,
        idleTimeoutSeconds: -1, bootImage: { ...m.image, displayName: "Team VM" }, initialNetwork: { publicEgress: true, httpsProxyHosts: [] } } })
    }
    if (u.pathname === "/v1/vms" && r.method === "GET") {
      expect(u.searchParams.get("createdBy")).toBe("caller")
      const labels = u.searchParams.getAll("label")
      const found = [...vms.values()].filter((m) => m.actor === control.actor && labels.every((label) => { const at = label.indexOf("="); return m.labels[label.slice(0, at)] === label.slice(at + 1) }))
      return Response.json({ items: found.map(bodyOf), nextCursor: null })
    }
    if (u.pathname === "/v1/vms" && r.method === "POST") {
      expect(key).toBeTruthy()
      const serialized = JSON.stringify(body), prior = intents.get(key!)
      if (prior && prior.body !== serialized) return Response.json({ _tag: "Conflict", message: "changed intent" }, { status: 409 })
      let m = prior ? vms.get(prior.id) : undefined
      if (!m) {
        // -1: never pause for idleness, unless CLOUD_IDLE_PAUSE is on (auto-pause.ts; Leo, 2026-10-30).
        expect(body?.idleTimeoutSeconds).toBe(-1)
        expect(body?.initialNetwork).toEqual({ publicEgress: true })
        expect(body?.labels.role).toBe("team-vm")
        const id = `vm_${String(++control.creates).padStart(26, "0")}`
        m = { id, displayName: body!.displayName, labels: body!.labels, state: "running", instance: `vm-native-${control.creates}`,
          key: await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair,
          present: true, retired: false, install: null, image: body!.image, actor: control.actor }
        vms.set(id, m); intents.set(key!, { body: serialized, id })
      }
      if (control.loseNextCreate) { control.loseNextCreate = false; throw new TypeError("lost API answer") }
      return Response.json({ ...bodyOf(m), bootImage: { ...m.image, displayName: "Team VM" }, initialNetwork: { publicEgress: true, httpsProxyHosts: [] } }, { status: 201 })
    }
    const id = u.pathname.split("/")[3]!, m = vms.get(id)
    if (!m && !control.forbidden && r.method === "DELETE" && u.pathname === `/v1/vms/${id}` && tombstones.has(id)) return new Response(null, { status: 204 })
    if (!m || control.forbidden) return notFound()
    if (u.pathname.endsWith("/identity")) return Response.json({ id, scheme: "sha256-v1", fingerprint: await instanceFingerprint(m.instance), ...(u.searchParams.get("checkPresence") === "true" ? { presence: m.present ? "present" : "missing" } : {}) })
    if (u.pathname === `/v1/vms/${id}`) {
      if (r.method === "DELETE") {
        vms.delete(id); tombstones.add(id)
        if (control.loseNextDelete) { control.loseNextDelete = false; throw new TypeError("lost API answer") }
        return new Response(null, { status: 204 })
      }
      return m.present ? Response.json(bodyOf(m)) : notFound()
    }
    if (u.pathname.endsWith("/start")) {
      if (m.retired) return Response.json({ _tag: "Conflict", message: "retired" }, { status: 409 })
      m.state = "running"; return Response.json(bodyOf(m))
    }
    if (u.pathname.endsWith("/retire")) { m.retired = true; m.state = "paused"; return Response.json({ id, state: "paused", retired: true }) }
    if (u.pathname.endsWith("/exec")) {
      expect(body?.linuxUser).toBe("root")
      const args = parseEnrollArgs(body!.command)
      if (!args) throw new Error("unexpected guest command")
      if (args.commit) { m.install = args.commit.install; return Response.json({ exitCode: 0, stdout: "", stderr: "" }) }
      const key = await crypto.subtle.exportKey("jwk", m.key.publicKey) as JsonWebKey
      const signature = b64u(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, m.key.privateKey, new TextEncoder().encode(bindMessage(args.team, args.epoch, m.instance, args.nonce))))
      return Response.json({ exitCode: 0, stdout: JSON.stringify({ instance_id: m.instance, public_jwk: { kty: "EC", crv: "P-256", x: key.x, y: key.y }, signature }), stderr: "" })
    }
    if (u.pathname.endsWith("/files/entries")) return Response.json({ entries: [{ name: "readme", kind: "file" }] })
    if (u.pathname.endsWith("/files/stat")) return Response.json({ kind: "file", size: 13, mode: 0o640, mtime: null, owner: "ubuntu", group: "ubuntu" })
    if (u.pathname.endsWith("/files/content")) {
      control.fileReads++
      const bytes = new TextEncoder().encode("saved content"), range = r.headers.get("range")
      const start = range ? Number(/^bytes=(\d+)-$/.exec(range)?.[1]) : 0
      control.fileOffsets.push(start)
      if (control.breakNextFileRead) {
        control.breakNextFileRead = false
        let sent = false
        return new Response(new ReadableStream<Uint8Array>({ pull(c) {
          if (!sent) { sent = true; c.enqueue(bytes.slice(0, 5)) } else c.error(new Error("lost saved-disk stream"))
        } }), { headers: { "content-length": String(bytes.length) } })
      }
      return new Response(bytes.slice(start), { status: range ? 206 : 200, headers: { "content-length": String(bytes.length - start), ...(range ? { "content-range": `bytes ${start}-${bytes.length - 1}/${bytes.length}` } : {}) } })
    }
    throw new Error(`unexpected API route ${r.method} ${u.pathname}`)
  }
  return { vms, calls, control, fetch: fetchFn }
}
