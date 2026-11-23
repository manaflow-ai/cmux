import { spawnSync } from "node:child_process"
import { describe, expect, it } from "vitest"
import { secretsLine, SECRETS_READER, secretValueProblem } from "../src/automation-secrets-wire.ts"

/** Per-automation secrets reach the command as environment variables through stdin, never its command line (AUTOMATIONS-SPEC section 12). */

const run = (secrets: Record<string, string>, rest: string, body: string) =>
  spawnSync("bash", ["-c", `${SECRETS_READER}${body}`], { input: `${secretsLine(secrets)}\n${rest}`, encoding: "utf8" })

describe("secrets on stdin", () => {
  it("exports every secret, keeps newlines, quotes and dollars whole, and leaves the rest of stdin to the command", () => {
    const sa = '{\n  "type": "service_account",\n  "private_key": "-----BEGIN KEY-----\\nabc $(rm -rf /) `x` \'q\'\\n"\n}'
    const r = run({ MODELS_CATALOG_TOKEN: "tok-1234567890", GOOGLE_CREDENTIALS: sa }, "the input\n", 'printf "%s|%s|" "$MODELS_CATALOG_TOKEN" "$GOOGLE_CREDENTIALS"; cat')
    expect(r.status, r.stderr).toBe(0)
    expect(r.stdout).toBe(`tok-1234567890|${sa}|the input\n`)
  })

  it("a child process started detached sees them (the start step's command runs in its own session)", () => {
    const r = run({ A_TOKEN: "abc" }, "", 'sh -c \'echo "$A_TOKEN"\' </dev/null')
    expect(r.stdout).toBe("abc\n")
  })

  it("no helper variable is left behind, and an empty set exports nothing", () => {
    const r = run({}, "", 'env | grep -c "^__cmux" || true')
    expect(r.stdout.trim()).toBe("0")
  })

  it("the line holds no value in clear text", () => {
    expect(secretsLine({ X_TOKEN: "very-secret-value" })).not.toContain("very-secret")
    expect(secretsLine({ X_TOKEN: "v" })).toMatch(/^[A-Za-z0-9+/=]*$/)
  })

  it("a value with a NUL byte is refused (it would cut the value)", () => {
    expect(secretValueProblem("a\u0000b")).toMatch(/NUL/)
    expect(secretValueProblem("fine\nvalue")).toBeUndefined()
  })
})
