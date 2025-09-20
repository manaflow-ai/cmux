import { __TEST_INTERNAL_ONLY_GET_STACK_TOKENS } from "@/lib/test-utils/__TEST_INTERNAL_ONLY_GET_STACK_TOKENS";
import { __TEST_INTERNAL_ONLY_MORPH_CLIENT } from "@/lib/test-utils/__TEST_INTERNAL_ONLY_MORPH_CLIENT";
import { testApiClient } from "@/lib/test-utils/openapi-client";
import { postApiSandboxesStart } from "@cmux/www-openapi-client";
import { describe, expect, it } from "vitest";

const ENVIRONMENT_ID =
  process.env.DEBUG_ENVIRONMENT_ID ?? "mn71k65q132jp5wb51p4btmzn57qvk3y";

describe("sandboxesRouter integration", () => {
  it("rejects providing a snapshotId not owned by the team", async () => {
    const tokens = await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS();
    const res = await postApiSandboxesStart({
      client: testApiClient,
      headers: { "x-stack-auth": JSON.stringify(tokens) },
      body: {
        teamSlugOrId: "manaflow",
        snapshotId: "snapshot_does_not_exist_for_team_test",
        ttlSeconds: 60,
      },
    });

    expect([403, 500]).toContain(res.response.status);
  });

  it(
    "starts sandbox for configured environment",
    {
      timeout: 45000,
    },
    async () => {
      const tokens = await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS();
      const res = await postApiSandboxesStart({
        client: testApiClient,
        headers: { "x-stack-auth": JSON.stringify(tokens) },
        body: {
          teamSlugOrId: "manaflow",
          environmentId: ENVIRONMENT_ID,
          ttlSeconds: 60,
        },
      });

      console.log("res", res.data);

      expect(res.response.status).toBe(200);
      if (!res.data) {
        throw new Error("No data returned from sandbox start");
      }
      expect(res.data.instanceId).toBeDefined();
      expect(res.data.vscodeUrl).toMatch(/^https?:\/\//);

      // run envctl --version
      const instance = await __TEST_INTERNAL_ONLY_MORPH_CLIENT.instances.get({
        instanceId: res.data.instanceId,
      });
      const envctlVersion = await instance.exec("envctl --version");
      console.log("envctlVersion", envctlVersion);
    }
  );
});
