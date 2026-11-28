import { defineConfig } from "vitest/config"

// This gate exercises the production sender's Web Crypto + HTTP boundary.
// It needs neither a Worker deployment nor the database/Miniflare bootstrap.
export default defineConfig({
  test: {
    environment: "node",
    include: ["test/apns-delivery-gate.test.ts"],
    testTimeout: 10_000,
  },
})
