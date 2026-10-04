import { describe, expect, it } from "vitest"
import { cloudConfig } from "../src/cloud-driver.ts"
import { createConfigProblem } from "../src/domains/cloud-plan.ts"

// CLOUD-DEV-SNAPSHOT: development boots only the latest cmux-next image lane snapshot (cmuxnp-dev-vmimg-*).
// No snapshot, or one without this environment's prefix, refuses create with a typed code and no fallback.
const dev = (extra: Record<string, string>) => ({ ENVIRONMENT: "development", CLOUD_NAME_PREFIX: "cmuxnp-dev-", CLOUD_FREESTYLE_API_KEY: "k", ...extra }) as never

describe("Cloud image config (CLOUD-DEV-SNAPSHOT)", () => {
  it("no snapshot configured: no image, problem missing", () => {
    expect(cloudConfig(dev({}))).toMatchObject({ prefix: "cmuxnp-dev-", image: null, imageProblem: "missing" })
  })
  it("a snapshot without this environment's prefix is refused, not used", () => {
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "sh-0070ed8844ad45649e3f9d2f575376bf" }))).toMatchObject({ image: null, imageProblem: "foreign" })
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-stg-vmimg-20261004" }))).toMatchObject({ image: null, imageProblem: "foreign" })
  })
  it("the image lane's dev snapshot is used", () => {
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-20261004a" }))).toMatchObject({ prefix: "cmuxnp-dev-", image: "cmuxnp-dev-vmimg-20261004a" })
  })
  it("create answers cloud.no_snapshot_configured (not retryable) for a missing or foreign snapshot; a missing key stays provider.unavailable", () => {
    expect(createConfigProblem(cloudConfig(dev({})))).toMatchObject({ code: "cloud.no_snapshot_configured", retryable: false })
    expect(createConfigProblem(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "sh-1" })))).toMatchObject({ code: "cloud.no_snapshot_configured", retryable: false })
    expect(createConfigProblem(cloudConfig(dev({ CLOUD_FREESTYLE_API_KEY: "", CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-1" })))).toMatchObject({ code: "cloud.provider.unavailable", retryable: true })
    expect(createConfigProblem(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-dev-vmimg-1" })))).toBeUndefined()
  })
})
