import { cloudflareTest } from "@cloudflare/vitest-pool-workers"
import { exportJWK, generateKeyPair } from "jose"
import { defineConfig } from "vitest/config"

// Test-only keys: a fake Stack signing key (its JWKS replaces Stack's published
// keys only when ENVIRONMENT=test) and the API's token signing key.
const stack = await generateKeyPair("ES256", { extractable: true })
const api = await generateKeyPair("ES256", { extractable: true })
const stackPublic = { ...(await exportJWK(stack.publicKey)), kid: "stack-test", alg: "ES256" }
const stackPrivate = { ...(await exportJWK(stack.privateKey)), kid: "stack-test" }
const apiPrivate = { ...(await exportJWK(api.privateKey)), kid: "api-test" }

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          ENVIRONMENT: "test",
          STACK_TEST_JWKS: JSON.stringify({ keys: [stackPublic] }),
          STACK_TEST_PRIVATE_JWK: JSON.stringify(stackPrivate),
          JWT_PRIVATE_JWK: JSON.stringify(apiPrivate)
        }
      }
    })
  ]
})
