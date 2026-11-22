import { describe, expect, it } from "vitest"
import { cloudConfig } from "../src/cloud-driver.ts"
import { createConfigProblem } from "../src/domains/cloud-plan.ts"

// CLOUD-DEV-SNAPSHOT: development boots only the latest cmux-next image lane snapshot (cmuxnp-dev-vmimg-*).
// No snapshot, or one without this environment's prefix, refuses create with a typed code and no fallback.
const dev = (extra: Record<string, string>) => ({ ENVIRONMENT: "development", CLOUD_NAME_PREFIX: "cmuxnp-dev-cld-", CLOUD_FREESTYLE_API_KEY: "k", ...extra }) as never

describe("Cloud image config (CLOUD-DEV-SNAPSHOT)", () => {
  it("no snapshot configured: no image, problem missing", () => {
    expect(cloudConfig(dev({}))).toMatchObject({ prefix: "cmuxnp-dev-cld-", image: null, imageProblem: "missing" })
  })
  it("a snapshot without this environment's prefix is refused, not used", () => {
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "sh-0070ed8844ad45649e3f9d2f575376bf" }))).toMatchObject({ image: null, imageProblem: "foreign" })
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-stg-vmimg-20261004" }))).toMatchObject({ image: null, imageProblem: "foreign" })
  })
  it("the image lane's dev snapshot is used", () => {
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-20261004a" }))).toMatchObject({ prefix: "cmuxnp-dev-cld-", image: "cmuxnp-dev-vmimg-20261004a" })
  })
  it("create answers cloud.no_snapshot_configured (not retryable) for a missing or foreign snapshot; a missing key stays provider.unavailable", () => {
    expect(createConfigProblem(cloudConfig(dev({})))).toMatchObject({ code: "cloud.no_snapshot_configured", retryable: false })
    expect(createConfigProblem(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "sh-1" })))).toMatchObject({ code: "cloud.no_snapshot_configured", retryable: false })
    expect(createConfigProblem(cloudConfig(dev({ CLOUD_FREESTYLE_API_KEY: "", CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-1" })))).toMatchObject({ code: "cloud.provider.unavailable", retryable: true })
    expect(createConfigProblem(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-1" })))).toBeUndefined()
  })
  it("the snapshot prefix is the image lane's cmuxnp-<env>-vmimg-, not the machine prefix (FREESTYLE-NAMES)", () => {
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-cld-vmimg-1" }))).toMatchObject({ image: null, imageProblem: "foreign" })
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-cld-vm-00000000000000000001" }))).toMatchObject({ image: null, imageProblem: "foreign" })
    expect(cloudConfig({ ENVIRONMENT: "staging", CLOUD_NAME_PREFIX: "cmuxnp-stg-cld-", CLOUD_FREESTYLE_API_KEY: "k", CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-stg-vmimg-7" } as never)).toMatchObject({ prefix: "cmuxnp-stg-cld-", image: "cmuxnp-stg-vmimg-7" })
    expect(cloudConfig({ ENVIRONMENT: "production", CLOUD_NAME_PREFIX: "cmuxnp-prod-cld-", CLOUD_FREESTYLE_API_KEY: "k", CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-prod-vmimg-7" } as never)).toMatchObject({ prefix: "cmuxnp-prod-cld-", image: "cmuxnp-prod-vmimg-7" })
    // The old bare env prefix is no longer this lane's.
    expect(cloudConfig(dev({ CLOUD_NAME_PREFIX: "cmuxnp-dev-", CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-1" }))).toMatchObject({ prefix: null, image: null })
    expect(cloudConfig({ ENVIRONMENT: "test", CLOUD_NAME_PREFIX: "cmuxnp-test-cld-", CLOUD_DRIVER: "fake" } as never)).toMatchObject({ prefix: "cmuxnp-test-cld-", image: "cmuxnp-test-vmimg-fake" })
  })
})

describe("Cloud environment tag (iss and bind file env)", () => {
  it("maps ENVIRONMENT to dev, stg, prod (test stays test); anything else has no tag", async () => {
    const { cloudEnvTag } = await import("../src/cloud-driver.ts")
    expect([cloudEnvTag("development"), cloudEnvTag("staging"), cloudEnvTag("production"), cloudEnvTag("test"), cloudEnvTag("local")]).toEqual(["dev", "stg", "prod", "test", null])
  })
  it("accepts only a bare https origin for the bind file api_origin", async () => {
    const { cloudApiOrigin } = await import("../src/cloud-driver.ts")
    expect(cloudApiOrigin({ CLOUD_API_ORIGIN: "https://cloud-api.cmux.dev" })).toBe("https://cloud-api.cmux.dev")
    expect(cloudApiOrigin({ CLOUD_API_ORIGIN: "https://cloud-api.cmux.dev/" })).toBe("https://cloud-api.cmux.dev")
    for (const bad of [undefined, "", "http://cloud-api.cmux.dev", "https://cloud-api.cmux.dev/v1", "https://u:p@cloud-api.cmux.dev", "https://x.dev?a=1", "not a url"])
      expect(cloudApiOrigin({ CLOUD_API_ORIGIN: bad })).toBeNull()
  })
})
