import { parseEnvironmentSpec, type EnvironmentSpec } from "../src/index.ts"

export const BASE = "sc-base-devbox"

export const spec = (over: Record<string, unknown> = {}): EnvironmentSpec => {
  const parsed = parseEnvironmentSpec({
    name: "cmux web",
    repo: "manaflow-ai/cmux@feat-cmux-next",
    setupScript: "cd web && bun install",
    env: [{ name: "NODE_ENV", value: "development" }, { name: "OPENAI_API_KEY", secret: "openai" }],
    ...over
  })
  if (!parsed.ok) throw new Error(parsed.error.message)
  return parsed.spec
}
