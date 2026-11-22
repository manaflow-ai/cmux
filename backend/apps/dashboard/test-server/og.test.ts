/**
 * Renders /og/invite/<code>.png through the built server (Nitro node-server output), so a
 * renderer dependency that breaks only in the bundled ESM (for example harfbuzzjs reading
 * `__dirname`) fails here instead of on Vercel. Builds `.output` first when it is missing
 * (CI runs `bun run build` just before). No static files are needed: the renderer and the
 * fonts are bundled into the server function.
 */
import { afterAll, beforeAll, expect, test } from "bun:test"
import { existsSync } from "node:fs"
import { createServer, type Server } from "node:http"
import type { AddressInfo } from "node:net"
import { join } from "node:path"

const root = join(import.meta.dir, "..")
const entry = join(root, ".output", "server", "index.mjs")
const CODE = "d0123456789ABCDEFGHJKMNPQRS"
const PNG = [0x89, 0x50, 0x4e, 0x47]

let api: Server
let server: ReturnType<typeof Bun.spawn> | undefined
let base = ""

const freePort = async () => {
  const s = createServer()
  await new Promise<void>((r) => s.listen(0, "127.0.0.1", r))
  const port = (s.address() as AddressInfo).port
  await new Promise((r) => s.close(r))
  return port
}

beforeAll(async () => {
  if (!existsSync(entry)) {
    const build = Bun.spawnSync(["bun", "run", "build"], { cwd: root, env: { ...process.env, NODE_ENV: "production", NITRO_PRESET: "node-server" }, stdout: "inherit", stderr: "inherit" })
    if (build.exitCode !== 0) throw new Error("dashboard build failed")
  }
  // Stand-in for the API's card endpoint: only CODE has an open invite.
  api = createServer((req, res) => {
    if (req.url === `/v1/invites/card/${CODE}`) {
      res.setHeader("content-type", "application/json")
      res.end(JSON.stringify({ first_name: "Lawrence", avatar_url: null }))
    } else {
      res.statusCode = 404
      res.end()
    }
  })
  await new Promise<void>((r) => api.listen(0, "127.0.0.1", r))
  const port = await freePort()
  base = `http://127.0.0.1:${port}`
  server = Bun.spawn(["node", entry], {
    cwd: root,
    env: { ...process.env, PORT: String(port), HOST: "127.0.0.1", CMUX_API_URL: `http://127.0.0.1:${(api.address() as AddressInfo).port}` },
    stdout: "inherit",
    stderr: "inherit"
  })
  for (let i = 0; i < 100; i++) {
    try {
      await fetch(`${base}/og/invite.png`)
      return
    } catch {
      await Bun.sleep(100)
    }
  }
  throw new Error("server did not start")
}, 300_000)

afterAll(() => {
  server?.kill()
  api?.close()
})

const render = async (path: string) => {
  const res = await fetch(`${base}${path}`)
  const body = new Uint8Array(await res.arrayBuffer())
  return { status: res.status, type: res.headers.get("content-type"), cache: res.headers.get("cache-control"), body, height: new DataView(body.buffer).getUint32(20) }
}

test("generic card (no open invite) renders a PNG with a short cache", async () => {
  const r = await render("/og/invite/dZZZZZZZZZZZZZZZZZZZZZZZZZZ.png")
  expect(r.status).toBe(200)
  expect(r.type).toBe("image/png")
  expect([...r.body.slice(0, 4)]).toEqual(PNG)
  expect(r.height).toBe(630)
  expect(r.cache).toContain("max-age=300")
})

test("personalized card renders and differs from the generic card", async () => {
  const [mine, generic] = await Promise.all([render(`/og/invite/${CODE}.png`), render("/og/invite/dZZZZZZZZZZZZZZZZZZZZZZZZZZ.png")])
  expect(mine.status).toBe(200)
  expect(mine.type).toBe("image/png")
  expect(mine.cache).toContain("max-age=86400")
  expect(Buffer.from(mine.body).equals(Buffer.from(generic.body))).toBe(false)
})

test("?s=square renders 1200x1200", async () => {
  const r = await render(`/og/invite/${CODE}.png?s=square`)
  expect(r.status).toBe(200)
  expect(r.type).toBe("image/png")
  expect(r.height).toBe(1200)
})
