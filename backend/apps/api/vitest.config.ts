import { cloudflareTest } from "@cloudflare/vitest-pool-workers"
import { exportJWK, exportPKCS8, generateKeyPair } from "jose"
import { defineConfig } from "vitest/config"

// Test-only keys: a fake Stack signing key (its JWKS replaces Stack's published
// keys only when ENVIRONMENT=test) and the API's token signing key.
const stack = await generateKeyPair("ES256", { extractable: true })
const api = await generateKeyPair("ES256", { extractable: true })
const stackPublic = { ...(await exportJWK(stack.publicKey)), kid: "stack-test", alg: "ES256" }
const stackPrivate = { ...(await exportJWK(stack.privateKey)), kid: "stack-test" }
const apiPrivate = { ...(await exportJWK(api.privateKey)), kid: "api-test" }
const githubApp = await generateKeyPair("RS256", { extractable: true })
const kek = Buffer.from(crypto.getRandomValues(new Uint8Array(32))).toString("base64")

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          ENVIRONMENT: "test",
          // Automation hard cap ceiling per team per month (USD); tests set it explicitly.
          AUTOMATION_CAP_CEILING_USD: "25",
          STACK_TEST_JWKS: JSON.stringify({ keys: [stackPublic] }),
          STACK_TEST_PRIVATE_JWK: JSON.stringify(stackPrivate),
          JWT_PRIVATE_JWK: JSON.stringify(apiPrivate),
          // Integration test secrets: provider HTTP is faked in the tests, these only make providers "configured".
          INTEGRATIONS_KEK: kek,
          // Home address ids (HMAC key, at least 32 characters); test-only.
          HOME_ADDRESS_KEY: "test-home-address-key-0123456789abcdef",
          GITHUB_APP_SLUG: "cmux-test",
          GITHUB_APP_CLIENT_ID: "Iv1.test",
          GITHUB_APP_CLIENT_SECRET: "gh-client-secret",
          GITHUB_APP_PRIVATE_KEY: await exportPKCS8(githubApp.privateKey),
          GITHUB_WEBHOOK_SECRET: "gh-webhook-secret",
          LINEAR_CLIENT_ID: "lin-client",
          LINEAR_CLIENT_SECRET: "lin-secret",
          LINEAR_WEBHOOK_SECRET: "lin-webhook-secret",
          SLACK_CLIENT_ID: "slack-client",
          SLACK_CLIENT_SECRET: "slack-secret",
          SLACK_SIGNING_SECRET: "slack-signing-secret",
          GOOGLE_CLIENT_ID: "google-client.apps.googleusercontent.com",
          GOOGLE_CLIENT_SECRET: "google-client-secret",
          // The dev project in Testing mode may ask for restricted Gmail scopes.
          GOOGLE_RESTRICTED_SCOPES: "testing",
          // Team VMs use the in-object fake provider (team-vm-driver.ts).
          TEAM_VM_DRIVER: "fake"
        }
      }
    })
  ]
})
