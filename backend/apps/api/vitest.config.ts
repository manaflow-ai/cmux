import { cloudflareTest } from "@cloudflare/vitest-pool-workers"
import { exportJWK, exportPKCS8, generateKeyPair } from "jose"
import { createHash } from "node:crypto"
import { defineConfig } from "vitest/config"
import { cloudAllowedTeams } from "./test/setup/cloud-teams.ts"

// Test-only keys: a fake Stack signing key (its JWKS replaces Stack's published
// keys only when ENVIRONMENT=test) and the API's token signing key.
const stack = await generateKeyPair("ES256", { extractable: true })
const api = await generateKeyPair("ES256", { extractable: true })
const stackPublic = { ...(await exportJWK(stack.publicKey)), kid: "stack-test", alg: "ES256" }
const stackPrivate = { ...(await exportJWK(stack.privateKey)), kid: "stack-test" }
const apiPrivate = { ...(await exportJWK(api.privateKey)), kid: "api-test" }
const githubApp = await generateKeyPair("RS256", { extractable: true })
// Test-only Google key that signs Pub/Sub push tokens (replaces Google's JWKS when ENVIRONMENT=test).
const pubsub = await generateKeyPair("RS256", { extractable: true })
const pubsubPublic = { ...(await exportJWK(pubsub.publicKey)), kid: "google-test", alg: "RS256" }
const pubsubPrivate = { ...(await exportJWK(pubsub.privateKey)), kid: "google-test" }
// Test-only link-token signing keys (two kids, the second active); never a real key.
const linkKeys: Record<string, unknown> = {}
for (const kid of ["test-link-1", "test-link-2"]) {
  const pair = await generateKeyPair("EdDSA", { crv: "Ed25519", extractable: true })
  linkKeys[kid] = { ...(await exportJWK(pair.privateKey)), kid }
}
// The user id of a test Stack subject (src/domains/user.ts userIdFor, local project id from wrangler.jsonc).
const testUser = (sub: string) => `user_${createHash("sha256").update(`stack:454ecd03-1db2-4050-845e-4ce5b0cd9895:${sub}`).digest("hex").slice(0, 20)}`
// A JWT-shaped test value with only `exp` (seconds); never a real token.
const fakeJwt = (exp: number) => ["e30", Buffer.from(JSON.stringify({ exp })).toString("base64url"), "sig"].join(".")
const kek = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64")

export default defineConfig({
  test: {
    // test-node/ runs under Node (vitest.node.config.ts): tests there spawn local programs, which workerd cannot.
    include: ["test/**/*.test.ts"],
    // Loads the Worker once per test file before any test runs (test/setup/warm-worker.ts).
    setupFiles: ["./test/setup/warm-worker.ts"],
    // The full parallel run of every file (309 s on a 32 vCPU Freestyle VM, 2026-10-16) makes each case about 9x
    // slower than when its file runs alone: cases of 0.5 s alone took 4.5 to 5.8 s, past the 5 s default. 20 s keeps
    // over 3x headroom over the slowest case without its own timeout. It hides nothing: the slow-tests reporter lists
    // every case over 2 s, and a case over 2 s alone has a slow part to fix (fixed waits, serial setup, big fixtures).
    testTimeout: 20_000,
    // An explicit list drops the reporter vitest adds on GitHub Actions (failure annotations), so it is named here.
    reporters: ["default", "./test/setup/slow-tests-reporter.ts", ...(process.env.GITHUB_ACTIONS === "true" ? ["github-actions"] : [])]
  },
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          ENVIRONMENT: "test",
          // Pairing's request-scoped Native calls are intercepted by its HTTP tests; no service key.
          CLOUD_VM_API_ORIGIN: "https://vm.test",
          // The hand classifier answers from the fake model (its reply shapes: chief-brain/fake.ts).
          HAND_CLASSIFIER_MODEL: "fake",
          // Automation hard cap ceiling per team per month (USD); tests set it explicitly.
          AUTOMATION_CAP_CEILING_USD: "25",
          STACK_TEST_JWKS: JSON.stringify({ keys: [stackPublic] }),
          STACK_TEST_PRIVATE_JWK: JSON.stringify(stackPrivate),
          JWT_PRIVATE_JWK: JSON.stringify(apiPrivate),
          // Integration test secrets: provider HTTP is faked in the tests, these only make providers "configured".
          INTEGRATIONS_KEK: kek,
          // Home address ids (HMAC key, at least 32 characters); test-only.
          HOME_ADDRESS_KEY: "test-home-address-key-0123456789abcdef",
          // Home attachment upload slots and download URLs (HMAC key); test-only.
          HOME_ATTACHMENT_KEY: "test-home-attachment-key-0123456789abcdef",
          HOME_ATTACHMENT_KEY_ID: "k2",
          HOME_ATTACHMENT_KEY_PREVIOUS: "test-home-attachment-key-previous-0123456789",
          HOME_ATTACHMENT_KEY_PREVIOUS_ID: "k1",
          // Presigned R2 PUTs for large files: fake S3 endpoint and token (URLs are only built, never called).
          HOME_ATTACHMENTS_S3_ENDPOINT: "https://test-account.r2.cloudflarestorage.com",
          HOME_ATTACHMENTS_S3_BUCKET: "cmux-home-attachments-local",
          HOME_ATTACHMENTS_S3_ACCESS_KEY_ID: "test-access-key-id",
          HOME_ATTACHMENTS_S3_SECRET_ACCESS_KEY: "test-secret-access-key",
          GITHUB_APP_SLUG: "cmux-test",
          GITHUB_APP_CLIENT_ID: "Iv1.test",
          GITHUB_APP_CLIENT_SECRET: "gh-client-secret",
          GITHUB_APP_PRIVATE_KEY: await exportPKCS8(githubApp.privateKey),
          GITHUB_WEBHOOK_SECRET: "gh-webhook-secret",
          LINEAR_CLIENT_ID: "lin-client",
          LINEAR_CLIENT_SECRET: "lin-secret",
          LINEAR_WEBHOOK_SECRET: "lin-webhook-secret",
          // Stack (Svix) webhook endpoint secret, test-only: whsec_ + base64 key bytes.
          STACK_WEBHOOK_SECRET: `whsec_${Buffer.from("test-stack-webhook-secret-0001").toString("base64")}`,
          SLACK_CLIENT_ID: "slack-client",
          SLACK_CLIENT_SECRET: "slack-secret",
          SLACK_SIGNING_SECRET: "slack-signing-secret",
          GOOGLE_CLIENT_ID: "google-client.apps.googleusercontent.com",
          GOOGLE_CLIENT_SECRET: "google-client-secret",
          // The dev project in Testing mode may ask for restricted Gmail scopes.
          GOOGLE_RESTRICTED_SCOPES: "testing",
          // The model router: one provider "configured" with a test-only key; its HTTP is faked in
          // test/inference-spend-facts.test.ts, and the daily line caps are small test amounts.
          INFERENCE_ENABLED: "1",
          INFERENCE_OPENROUTER_KEY: "test-openrouter-key",
          INFERENCE_DAILY_CAP_USD: "5",
          // The usage reconcile worker's service key for /v1/internal/billing/levels; test-only.
          BILLING_LEVELS_KEY: "test-billing-levels-key-0123456789abcdef",
          // The usage sync's payment key: a test-mode shape; the payment service is faked in test/inference-spend-facts.test.ts.
          STRIPE_USAGE_KEY: "sk_test_fake-usage-sync-key",
          // Chief brains (chief-brain/brain-do.ts): wakes reach the brain; the fake model (no AI binding in tests).
          CHIEF_BRAIN_ENABLED: "1",
          HANDS_ENABLED: "1",
          // The opencode brain (O) is selectable; no container binds here, so an O Chief falls back to P (chief-brain-opencode-route.test.ts).
          CHIEF_OPENCODE_ENABLED: "1",
          // Cloud Chief D (chief-durable/) is selectable per Chief (brain_impl "durable"); test/chief-durable.test.ts.
          CHIEF_DURABLE_ENABLED: "1",
          // Test-only fault hooks (chief-fault.ts): evict a brain object in the middle of a turn.
          CHIEF_FAULT_HOOKS: "1",
          // The metered Claude route and its sign-in refresh, faked at their HTTP boundary in
          // test/chief-brain-claude.test.ts. Test-only values: an expired fake access token and a fake refresh token.
          CHIEF_BRAIN_CLAUDE_URL: "https://claude.test/api/claude-david",
          CHIEF_BRAIN_CLAUDE_REFRESH_URL: "https://auth.test/api/v1/auth/sessions/current/refresh",
          CHIEF_BRAIN_CLAUDE_STACK_AUTH: JSON.stringify({ accessToken: fakeJwt(1), refreshToken: "test-refresh-token-not-real" }),
          CHIEF_BRAIN_CLAUDE_OWNERS: testUser("brain-claude-ok"),
          // The second allowed owner comes from the no-deploy list (a secret on staging).
          CHIEF_BRAIN_CLAUDE_OWNERS_EXTRA: testUser("brain-claude-fail"),
          CHIEF_BRAIN_FALLBACK_MODEL: "fake",
          // Old pi entries are pruned at each turn start (chief-brain/pi-prune.ts), as on staging.
          CHIEF_BRAIN_PRUNE_PI: "1",
          // Team VMs use the in-object fake provider (team-vm-driver.ts).
          TEAM_VM_DRIVER: "fake",
          // The team VM bind runs against the fake guest (team-vm-fake-guest.ts).
          TEAM_VM_BIND_ENABLED: "1",
          // Cloud machines use the in-object fake provider under the test prefix (cloud-driver.ts).
          CLOUD_DRIVER: "fake",
          // ACP chat trajectories kept outside the VM (cloud-trajectory.ts); off unless "1".
          CLOUD_TRAJECTORIES_ENABLED: "1",
          CLOUD_API_ORIGIN: "https://api.test",
          CLOUD_LINK_SIGNING_KEYS: JSON.stringify({ active: "test-link-2", keys: linkKeys, published_at: { "test-link-1": 0, "test-link-2": 0 } }),
          CLOUD_ADMIN_KEY: "test-cloud-admin-key-0123456789abcdef",
          // userIdFor(STACK_PROJECT_ID, "ops_person_1"): the only person the abandoned-clear route accepts in tests.
          CLOUD_ADMIN_USERS: "user_6412abe5b2830d00012b",
          CLOUD_NAME_PREFIX: "cmuxnp-test-cld-",
          // PlatformMachines answers (test/platform-machines.test.ts); development only among the deployments.
          PLATFORM_MACHINES: "on",
          PLATFORM_AGENT_GATEWAY: "on",
          // Only these teams get the stub plan and provider calls (P1-1); test/setup/cloud-teams.ts.
          CLOUD_ALLOWED_TEAMS: cloudAllowedTeams().join(","),
          GOOGLE_PUBSUB_TOPIC: "projects/cmux-integrations-dev/topics/gmail-push",
          GOOGLE_PUBSUB_AUDIENCE: "https://api.test/v1/hooks/google/pubsub",
          GOOGLE_PUBSUB_SERVICE_ACCOUNT: "gmail-push-invoker@cmux-integrations-dev.iam.gserviceaccount.com",
          GOOGLE_PUBSUB_TEST_JWKS: JSON.stringify({ keys: [pubsubPublic] }),
          GOOGLE_PUBSUB_TEST_PRIVATE_JWK: JSON.stringify(pubsubPrivate)
        }
      }
    })
  ]
})
