import { defineConfig } from "vitest/config"

// Tests that run a guest program with the local python3 (child processes, a temporary tree): Node, not workerd.
export default defineConfig({
  test: {
    include: ["test-node/**/*.test.ts"],
    environment: "node",
  },
})
