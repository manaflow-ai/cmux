import { describe, expect, it } from "vitest"
import { cloudConfig } from "../src/cloud-driver.ts"
import { createConfigProblem } from "../src/domains/cloud-plan.ts"

// CLOUD-DEV-SNAPSHOT: development boots only the latest cmux-next image lane snapshot (cmuxnp-dev-vmimg-*).
// No snapshot, or one without this environment's prefix, refuses create with a typed code and no fallback.
const dev = (extra: Record<string, string>) => ({ ENVIRONMENT: "development", CLOUD_NAME_PREFIX: "cmuxnp-dev-cld-", CLOUD_FREESTYLE_API_KEY: "k", ...extra }) as never

describe("Cloud image config (CLOUD-DEV-SNAPSHOT)", () => {
  it("a snapshot without this environment's prefix is refused, not used", () => {
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "sh-0070ed8844ad45649e3f9d2f575376bf" }))).toMatchObject({ image: null, imageProblem: "foreign" })
    expect(cloudConfig(dev({ CLOUD_FREESTYLE_SNAPSHOT: "cmuxnp-stg-vmimg-20261004" }))).toMatchObject({ image: null, imageProblem: "foreign" })
  })
})

describe("Cloud environment tag (iss and bind file env)", () => {
  it("accepts only a bare https origin for the bind file api_origin", async () => {
    const { cloudApiOrigin } = await import("../src/cloud-driver.ts")
    expect(cloudApiOrigin({ CLOUD_API_ORIGIN: "https://cloud-api.cmux.dev" })).toBe("https://cloud-api.cmux.dev")
    expect(cloudApiOrigin({ CLOUD_API_ORIGIN: "https://cloud-api.cmux.dev/" })).toBe("https://cloud-api.cmux.dev")
    for (const bad of [undefined, "", "http://cloud-api.cmux.dev", "https://cloud-api.cmux.dev/v1", "https://u:p@cloud-api.cmux.dev", "https://x.dev?a=1", "not a url"])
      expect(cloudApiOrigin({ CLOUD_API_ORIGIN: bad })).toBeNull()
  })
})
