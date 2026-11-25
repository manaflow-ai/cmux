// The pair matrix's `relay-worker` arm: the real Worker (TeamHub signaling, LinkRelay, the relay cache) in miniflare on
// loopback, for cmux-mobile-link `tests/pair_matrix_mac_asleep.rs`, offline (no Cloudflare account, no network).
//
// `node scripts/pair-matrix-worker.mjs` (after `npm ci`): starts the Worker on 127.0.0.1 with ENVIRONMENT=test (the
// fixtures vitest.config.ts uses), registers one Mac and one phone of user alice on team-a, and prints one line,
// `PAIRWORKER {"url","team","mac":{"id","token"},"phone":{"id","token"}}`, then serves until stdin closes.
// Env: LINK_RELAY_CACHE=on turns the relay cache (#55970) on; off by default, as deployed.

import { exportJWK, generateKeyPair, SignJWT } from "jose"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { unstable_startWorker } from "wrangler"

const here = dirname(fileURLToPath(import.meta.url))
const stack = await generateKeyPair("ES256", { extractable: true })
const stackPublic = { ...(await exportJWK(stack.publicKey)), kid: "stack-test", alg: "ES256" }
const plain = (value) => ({ type: "plain_text", value })

const worker = await unstable_startWorker({
  config: join(here, "..", "wrangler.jsonc"),
  entrypoint: join(here, "pair-matrix-entry.ts"),
  bindings: {
    ENVIRONMENT: plain("test"),
    TEAM_HUB_RETIRE_RETRY_MS: plain("0"),
    LINK_RELAY_CACHE: plain(process.env.LINK_RELAY_CACHE ?? "off"),
    STACK_TEST_JWKS: plain(JSON.stringify({ keys: [stackPublic] })),
    STACK_TEST_TEAMS: plain(JSON.stringify({ alice: ["team-a"] }))
  },
  dev: { server: { hostname: "127.0.0.1", port: 0 }, inspector: false, watch: false, logLevel: "warn" }
})
await worker.ready
const url = (await worker.url).toString().replace(/\/$/, "")

const projects = JSON.parse(
  (await import("wrangler")).unstable_readConfig({ config: join(here, "..", "wrangler.jsonc") }, { hideWarnings: true }).vars.STACK_PROJECTS
)
const project = projects.find((p) => p.label === "dev").id
const token = await new SignJWT({})
  .setProtectedHeader({ alg: "ES256", kid: "stack-test" })
  .setIssuer(`https://api.stack-auth.com/api/v1/projects/${project}`)
  .setAudience(project)
  .setSubject("alice")
  .setIssuedAt()
  .setExpirationTime("2h")
  .sign(stack.privateKey)

const register = async (kind) => {
  const deviceId = crypto.randomUUID()
  const res = await fetch(`${url}/v1/devices`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ deviceId, kind, name: `pair-matrix-${kind}`, teamId: "team-a" })
  })
  if (res.status !== 200) throw new Error(`register ${kind}: ${res.status} ${await res.text()}`)
  return { id: deviceId, token }
}

const mac = await register("mac")
const phone = await register("phone")
console.log(`PAIRWORKER ${JSON.stringify({ url, team: "team-a", mac, phone })}`)

process.stdin.resume()
process.stdin.on("end", async () => {
  await worker.dispose()
  process.exit(0)
})
