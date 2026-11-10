import { cloudflareTest } from "@cloudflare/vitest-pool-workers"
import { exportJWK, generateKeyPair } from "jose"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import { defineConfig } from "vitest/config"
import { unstable_readConfig } from "wrangler"

// Test-only fake Stack signing key: its JWKS replaces Stack's published keys when ENVIRONMENT=test.
const stack = await generateKeyPair("ES256", { extractable: true })
const stackPublic = { ...(await exportJWK(stack.publicKey)), kid: "stack-test", alg: "ES256" }
const stackPrivate = { ...(await exportJWK(stack.privateKey)), kid: "stack-test" }

// The APNS_TOPICS each deployed environment declares in wrangler.jsonc: the tests run on the top level,
// so test/apns-topics.test.ts reads these to pin the bundles dev and prod push to.
const wranglerPath = join(dirname(fileURLToPath(import.meta.url)), "wrangler.jsonc")
const deployedApnsTopics = Object.fromEntries(
  ["dev", "prod"].map((name) => [name, String(unstable_readConfig({ config: wranglerPath, env: name }, { hideWarnings: true }).vars.APNS_TOPICS ?? "")])
)

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          ENVIRONMENT: "test",
          TEAM_HUB_RETIRE_RETRY_MS: "0",
          // A fake server key for the primary (dev) project: team creation runs its real Stack requests,
          // which test/teams.test.ts answers with a fake Stack fetch. Membership and invites stay on the
          // ENVIRONMENT=test fixtures below.
          STACK_SECRET_SERVER_KEY: "test-server-key",
          STACK_TEST_JWKS: JSON.stringify({ keys: [stackPublic] }),
          STACK_TEST_PRIVATE_JWK: JSON.stringify(stackPrivate),
          TEST_DEPLOYED_APNS_TOPICS: JSON.stringify(deployedApnsTopics),
          // userId -> teams (dev project); alice and bob share team-a, mallory is only in team-m.
          // "<prod project>:<userId>" -> teams (prod project): prod alice and pat share team-p.
          STACK_TEST_TEAMS: JSON.stringify({
            alice: ["team-a"],
            bob: ["team-a"],
            mallory: ["team-m"],
            carol: ["team-c"],
            dave: ["team-c"],
            erin: ["team-e"],
            // test/isolation.test.ts: uma and vic share team-u (two users on one team).
            uma: ["team-u", "team-u2", "team-legacy", "team-legacy-3", "team-legacy-4"],
            yan: [],
            vic: ["team-u"],
            "9790718f-14cd-4f7e-824d-eaf527a82b82:alice": ["team-p"],
            "9790718f-14cd-4f7e-824d-eaf527a82b82:pat": ["team-p"]
          })
        }
      }
    })
  ]
})
