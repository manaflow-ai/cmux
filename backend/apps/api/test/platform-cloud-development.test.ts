import { describe, expect, it } from "vitest"
// @ts-expect-error a Vite raw import (the test runner bundles it; the Worker build never sees it)
import wranglerText from "../wrangler.jsonc?raw"

/**
 * The development Worker (wrangler.jsonc env.development) hands NEXT Cloud to cmux-platform-development,
 * which owns CloudDO there (cmux-platform docs/port-cloud-worker.md 3.3): the forwarder sends the `cloud`
 * surface over PLATFORM, and CLOUD_DO is the platform's class, so this Worker's own callers reach the same
 * objects. Staging and production keep their own CloudDO.
 */

/** JSONC to JSON: drops comments outside strings (wrangler.jsonc has no trailing commas). */
const stripComments = (text: string): string => {
  let out = ""
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!
    if (c === '"') {
      let j = i + 1
      while (j < text.length && text[j] !== '"') j += text[j] === "\\" ? 2 : 1
      out += text.slice(i, j + 1)
      i = j
    } else if (c === "/" && text[i + 1] === "/") {
      while (i < text.length && text[i] !== "\n") i++
      out += "\n"
    } else out += c
  }
  return out
}

type DoBinding = { name: string; class_name: string; script_name?: string }
type EnvBlock = {
  name: string
  vars: Record<string, string>
  durable_objects: { bindings: Array<DoBinding> }
  services?: Array<{ binding: string; service: string; entrypoint?: string }>
  migrations?: Array<Record<string, unknown>>
}
const envs = () => (JSON.parse(stripComments(wranglerText as string)) as { env: Record<string, EnvBlock> }).env
const cloudDo = (e: EnvBlock) => e.durable_objects.bindings.find((b) => b.name === "CLOUD_DO")

describe("development routes NEXT Cloud to cmux-platform-development", () => {
  it("forwards the cloud surface over PLATFORM and binds the platform's CloudDO", () => {
    const dev = envs().development!
    expect(dev.name).toBe("cmux-api-development")
    expect(dev.vars.PLATFORM_SURFACES).toBe("cloud")
    expect(dev.services).toContainEqual({ binding: "PLATFORM", service: "cmux-platform-development" })
    expect(cloudDo(dev)).toEqual({ name: "CLOUD_DO", class_name: "CloudDO", script_name: "cmux-platform-development" })
    // The class's own migration stays here until the class is deleted from this Worker.
    expect(JSON.stringify(dev.migrations)).toContain('"CloudDO"')
    expect(JSON.stringify(dev.migrations)).not.toContain("deleted_classes")
  })

  it("leaves staging's and production's CloudDO their own", () => {
    for (const name of ["staging", "production"]) {
      const e = envs()[name]!
      expect(cloudDo(e), name).toEqual({ name: "CLOUD_DO", class_name: "CloudDO" })
      expect(JSON.stringify(e.services ?? []), name).not.toContain("cmux-platform-development")
    }
  })
})
