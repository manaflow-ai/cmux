import { env, exports } from "cloudflare:workers"
import { importJWK, SignJWT, type JWK } from "jose"
import { expect } from "vitest"

const testEnv = env as unknown as { STACK_PROJECTS: string; STACK_TEST_PRIVATE_JWK: string }
const projects = JSON.parse(testEnv.STACK_PROJECTS) as Array<{ id: string; label: string }>
/** The configured Stack projects (wrangler.jsonc top level): dev is primary, prod the second. */
export const DEV_PROJECT = projects.find((p) => p.label === "dev")!.id
export const PROD_PROJECT = projects.find((p) => p.label === "prod")!.id
export const worker = (exports as unknown as { default: Fetcher }).default

/** A Stack access token signed by the test key; `project` picks the issuer (default the dev project). */
export const token = async (sub: string, opts: { audience?: string; anonymous?: boolean; restricted?: boolean; project?: string } = {}) =>
  new SignJWT({ ...(opts.anonymous ? { is_anonymous: true } : {}), ...(opts.restricted ? { is_restricted: true } : {}) })
    .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
    .setIssuer(`https://api.stack-auth.com/api/v1/projects/${opts.project ?? DEV_PROJECT}`)
    .setAudience(opts.audience ?? opts.project ?? DEV_PROJECT)
    .setSubject(sub)
    .setIssuedAt()
    .setExpirationTime("10m")
    .sign(await importJWK(JSON.parse(testEnv.STACK_TEST_PRIVATE_JWK) as JWK, "ES256"))

export const call = async (method: string, path: string, tok: string | undefined, body?: unknown) => {
  const res = await worker.fetch(`https://api.test${path}`, {
    method,
    headers: { "content-type": "application/json", ...(tok ? { authorization: `Bearer ${tok}` } : {}) },
    ...(body === undefined ? {} : { body: JSON.stringify(body) })
  })
  return { status: res.status, json: (await res.json()) as any }
}

export const register = async (tok: string, kind: "mac" | "phone", teamId: string, name = `${kind}-${crypto.randomUUID().slice(0, 4)}`) => {
  const deviceId = crypto.randomUUID()
  const r = await call("POST", "/v1/devices", tok, { deviceId, kind, name, teamId })
  expect(r.status).toBe(200)
  return deviceId
}

export interface Sock {
  ws: WebSocket
  frames: Array<any>
  binary: Array<Uint8Array>
  closed: boolean
  until(pred: (s: Sock) => boolean): Promise<void>
  send(f: unknown): void
}

export const connect = async (tok: string, teamId: string, deviceId: string, viaSubprotocol = false): Promise<Sock> => {
  const headers: Record<string, string> = { Upgrade: "websocket" }
  if (viaSubprotocol) headers["Sec-WebSocket-Protocol"] = `cmux-mobile.v1, bearer.${tok}`
  else headers.authorization = `Bearer ${tok}`
  const res = await worker.fetch(`https://api.test/v1/teams/${teamId}/signal?deviceId=${deviceId}`, { headers })
  expect(res.status).toBe(101)
  const ws = res.webSocket!
  const waiters: Array<() => void> = []
  const s: Sock = {
    ws,
    frames: [],
    binary: [],
    closed: false,
    until: async (pred) => {
      const deadline = Date.now() + 3000
      while (!pred(s)) {
        if (Date.now() > deadline) throw new Error(`timed out; frames: ${JSON.stringify(s.frames)}`)
        await new Promise<void>((r) => {
          waiters.push(r)
          setTimeout(r, 50)
        })
      }
    },
    send: (f) => ws.send(JSON.stringify(f))
  }
  // Binary frames arrive as Blobs in workerd; a promise chain keeps them in order.
  let chain = Promise.resolve()
  ws.addEventListener("message", (e) => {
    chain = chain.then(async () => {
      if (typeof e.data === "string") s.frames.push(JSON.parse(e.data))
      else s.binary.push(new Uint8Array(e.data instanceof Blob ? await e.data.arrayBuffer() : (e.data as ArrayBuffer)))
      waiters.splice(0).forEach((w) => w())
    })
  })
  ws.addEventListener("close", () => {
    s.closed = true
    waiters.splice(0).forEach((w) => w())
  })
  ws.accept()
  return s
}
