import { cloudflareTest } from "@cloudflare/vitest-pool-workers"
import { exportJWK, generateKeyPair } from "jose"
import { defineConfig } from "vitest/config"

// Test-only fake Stack signing key: its JWKS replaces Stack's published keys when ENVIRONMENT=test.
const stack = await generateKeyPair("ES256", { extractable: true })
const stackPublic = { ...(await exportJWK(stack.publicKey)), kid: "stack-test", alg: "ES256" }
const stackPrivate = { ...(await exportJWK(stack.privateKey)), kid: "stack-test" }

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
