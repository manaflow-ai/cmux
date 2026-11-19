import { describe, expect, it } from "vitest"
import { integrationCallbackUrl } from "../src/integrations/state.ts"

/** Provider redirects (GitHub's App callback, OAuth redirect_uri) and the completion's redirect_uri. */
describe("integrationCallbackUrl", () => {
  it("uses the console's own origin by default", () => {
    expect(integrationCallbackUrl({ DASHBOARD_ORIGIN: "https://console-staging.cmux.dev/" })).toBe("https://console-staging.cmux.dev/integrations/callback")
  })

  it("sends development's connects to the console named for them, keeping DASHBOARD_ORIGIN for the rest", () => {
    expect(integrationCallbackUrl({ DASHBOARD_ORIGIN: "http://localhost:3010", INTEGRATIONS_CALLBACK_ORIGIN: "https://console-staging.cmux.dev" })).toBe("https://console-staging.cmux.dev/integrations/callback")
  })

  it("treats an empty override as unset", () => {
    expect(integrationCallbackUrl({ DASHBOARD_ORIGIN: "http://localhost:3010", INTEGRATIONS_CALLBACK_ORIGIN: "" })).toBe("http://localhost:3010/integrations/callback")
  })
})
