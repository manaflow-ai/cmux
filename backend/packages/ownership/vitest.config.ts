import { defineConfig } from "vitest/config"

// The model runs thousands of randomized protocol histories per test.
export default defineConfig({ test: { testTimeout: 300_000 } })
