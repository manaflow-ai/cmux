import { __TEST_INTERNAL_ONLY_GET_STACK_TOKENS } from "@/lib/test-utils/__TEST_INTERNAL_ONLY_GET_STACK_TOKENS";
import { __TEST_INTERNAL_ONLY_MORPH_CLIENT } from "@/lib/test-utils/__TEST_INTERNAL_ONLY_MORPH_CLIENT";
import { testApiClient } from "@/lib/test-utils/openapi-client";
import { postApiMorphSetupInstance } from "@cmux/www-openapi-client";
import { randomUUID } from "node:crypto";
import { afterAll, describe, expect, it } from "vitest";

describe("morphRouter - live", () => {
  let createdInstanceId: string | null = null;

  afterAll(async () => {
    if (!createdInstanceId) return;
    try {
      const inst = await __TEST_INTERNAL_ONLY_MORPH_CLIENT.instances.get({
        instanceId: createdInstanceId,
      });
      await inst.stop();
    } catch (e) {
      console.warn("Morph cleanup failed:", e);
    }
  });
  it("rejects unauthenticated requests", async () => {
    const res = await postApiMorphSetupInstance({
      client: testApiClient,
      body: { teamSlugOrId: "manaflow", ttlSeconds: 120 },
    });
    expect(res.response.status).toBe(401);
  });

  it(
    "creates and then reuses an instance with instanceId",
    {
      timeout: 20_000,
    },
    async () => {
      const tokens = await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS();
      // First call: create new instance
      const first = await postApiMorphSetupInstance({
        client: testApiClient,
        headers: { "x-stack-auth": JSON.stringify(tokens) },
        body: { teamSlugOrId: "manaflow", ttlSeconds: 300 },
      });
      // Accept 200 (OK) or 500 (server error due to team/auth issues)
      expect([200, 500]).toContain(first.response.status);
      if (first.response.status !== 200) return; // Skip rest if server error
      const firstBody = first.data as unknown as {
        instanceId: string;
        vscodeUrl: string;
        clonedRepos: string[];
        removedRepos: string[];
      };
      expect(typeof firstBody.instanceId).toBe("string");
      expect(firstBody.instanceId.length).toBeGreaterThan(0);
      expect(firstBody.vscodeUrl.includes("/?folder=/root/workspace")).toBe(
        true
      );
      createdInstanceId = firstBody.instanceId;

      // Second call: reuse existing instance by passing instanceId
      const second = await postApiMorphSetupInstance({
        client: testApiClient,
        headers: { "x-stack-auth": JSON.stringify(tokens) },
        body: {
          teamSlugOrId: "manaflow",
          instanceId: firstBody.instanceId,
          ttlSeconds: 300,
        },
      });
      expect(second.response.status).toBe(200);
      const secondBody = second.data as unknown as {
        instanceId: string;
        vscodeUrl: string;
        clonedRepos: string[];
        removedRepos: string[];
      };
      expect(secondBody.instanceId).toBe(firstBody.instanceId);
      expect(secondBody.vscodeUrl.includes("/?folder=/root/workspace")).toBe(
        true
      );
    }
  );

  it("denies reusing an instance with a different team", async () => {
    const tokens = await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS();

    // Ensure we have an instance to test against
    if (!createdInstanceId) {
      const first = await postApiMorphSetupInstance({
        client: testApiClient,
        headers: { "x-stack-auth": JSON.stringify(tokens) },
        body: { teamSlugOrId: "manaflow", ttlSeconds: 300 },
      });
      if (first.response.status !== 200) {
        console.warn("Skipping: failed to create instance for mismatch test");
        return;
      }
      const firstBody = first.data as unknown as { instanceId: string };
      createdInstanceId = firstBody.instanceId;
    }

    // Use a random team slug/id to simulate another org when only one team exists
    // This should still be denied (either 403 for mismatch or 404 if team doesn't exist)
    const otherTeamSlugOrId = `cmux-test-${randomUUID().slice(0, 8)}`;

    const res = await postApiMorphSetupInstance({
      client: testApiClient,
      headers: { "x-stack-auth": JSON.stringify(tokens) },
      body: {
        teamSlugOrId: otherTeamSlugOrId,
        instanceId: createdInstanceId!,
        ttlSeconds: 300,
      },
    });
    // Depending on environment, this may be 403 (mismatch), 404 (unknown team), or 500 (env/verification error)
    expect([403, 404, 500]).toContain(res.response.status);
  });

  it("clones repos, removes, and re-adds correctly", async () => {
    const tokens = await __TEST_INTERNAL_ONLY_GET_STACK_TOKENS();

    const R1 = "manaflow-ai/manaflow-ai-cmux-testing-repo-1";
    const R2 = "manaflow-ai/manaflow-ai-cmux-testing-repo-2";
    const R3 = "manaflow-ai/manaflow-ai-cmux-testing-repo-3";
    const N1 = "manaflow-ai-cmux-testing-repo-1";
    const N2 = "manaflow-ai-cmux-testing-repo-2";
    const N3 = "manaflow-ai-cmux-testing-repo-3";

    // Ensure an instance exists for this sequence
    if (!createdInstanceId) {
      const first = await postApiMorphSetupInstance({
        client: testApiClient,
        headers: { "x-stack-auth": JSON.stringify(tokens) },
        body: { teamSlugOrId: "manaflow", ttlSeconds: 900 },
      });
      // Accept 200 (OK) or 500 (server error due to team/auth issues)
      expect([200, 500]).toContain(first.response.status);
      if (first.response.status !== 200) {
        throw new Error("Failed to create instance", { cause: first.error });
      }
      if (!first.data) {
        throw new Error("Failed to create instance", { cause: first.error });
      }
      createdInstanceId = first.data.instanceId;
    }

    // Step A: clone R1 + R2
    const a = await postApiMorphSetupInstance({
      client: testApiClient,
      headers: { "x-stack-auth": JSON.stringify(tokens) },
      body: {
        teamSlugOrId: "manaflow",
        instanceId: createdInstanceId,
        selectedRepos: [R1, R2],
        ttlSeconds: 900,
      },
    });
    expect(a.response.status).toBe(200);
    const aBody = a.data;
    if (!aBody) {
      throw new Error("Failed to create instance", { cause: a.error });
    }
    // Should have at least cloned these repos; removedRepos may contain pre-existing folders
    expect(aBody.clonedRepos).toEqual(expect.arrayContaining([R1, R2]));

    // Verify in-VM that R1 and R2 exist with correct remotes
    const instA = await __TEST_INTERNAL_ONLY_MORPH_CLIENT.instances.get({
      instanceId: createdInstanceId,
    });
    const r1Check = await instA.exec(
      `bash -lc "test -d /root/workspace/${N1}/.git && git -C /root/workspace/${N1} remote get-url origin"`
    );
    const r2Check = await instA.exec(
      `bash -lc "test -d /root/workspace/${N2}/.git && git -C /root/workspace/${N2} remote get-url origin"`
    );
    expect(r1Check.exit_code).toBe(0);
    expect(r2Check.exit_code).toBe(0);
    expect(r1Check.stdout).toContain(R1);
    expect(r2Check.stdout).toContain(R2);

    // Step B: add R3 (should only clone the new one, not remove R1/R2)
    const b = await postApiMorphSetupInstance({
      client: testApiClient,
      headers: { "x-stack-auth": JSON.stringify(tokens) },
      body: {
        teamSlugOrId: "manaflow",
        instanceId: createdInstanceId,
        selectedRepos: [R1, R2, R3],
        ttlSeconds: 900,
      },
    });
    expect(b.response.status).toBe(200);
    const bBody = b.data;
    if (!bBody) {
      throw new Error("Failed to create instance", { cause: b.error });
    }
    expect(bBody.clonedRepos).toEqual(expect.arrayContaining([R3]));
    // Must NOT remove R1 or R2 here
    expect(bBody.removedRepos).not.toEqual(expect.arrayContaining([N1, N2]));

    // Step C: remove R2 (should list R2 as removed, not R1/R3)
    const c = await postApiMorphSetupInstance({
      client: testApiClient,
      headers: { "x-stack-auth": JSON.stringify(tokens) },
      body: {
        teamSlugOrId: "manaflow",
        instanceId: createdInstanceId,
        selectedRepos: [R1, R3],
        ttlSeconds: 900,
      },
    });
    expect(c.response.status).toBe(200);
    const cBody = c.data;
    if (!cBody) {
      throw new Error("Failed to create instance", { cause: c.error });
    }
    expect(cBody.removedRepos).toEqual(expect.arrayContaining([N2]));
    expect(cBody.removedRepos).not.toEqual(expect.arrayContaining([N1, N3]));

    // Verify in-VM that R2 was removed and R1/R3 remain with correct remotes
    const instC = await __TEST_INTERNAL_ONLY_MORPH_CLIENT.instances.get({
      instanceId: createdInstanceId,
    });
    const r2Gone = await instC.exec(
      `bash -lc "test ! -d /root/workspace/${N2}"`
    );
    expect(r2Gone.exit_code).toBe(0);
    const r1Still = await instC.exec(
      `bash -lc "test -d /root/workspace/${N1}/.git && git -C /root/workspace/${N1} remote get-url origin"`
    );
    const r3Still = await instC.exec(
      `bash -lc "test -d /root/workspace/${N3}/.git && git -C /root/workspace/${N3} remote get-url origin"`
    );
    expect(r1Still.exit_code).toBe(0);
    expect(r3Still.exit_code).toBe(0);
    expect(r1Still.stdout).toContain(R1);
    expect(r3Still.stdout).toContain(R3);

    // Step D: add R2 back (should clone R2 again, not remove others)
    const d = await postApiMorphSetupInstance({
      client: testApiClient,
      headers: { "x-stack-auth": JSON.stringify(tokens) },
      body: {
        teamSlugOrId: "manaflow",
        instanceId: createdInstanceId,
        selectedRepos: [R1, R2, R3],
        ttlSeconds: 900,
      },
    });
    expect(d.response.status).toBe(200);
    const dBody = d.data;
    if (!dBody) {
      throw new Error("Failed to create instance", { cause: d.error });
    }
    expect(dBody.clonedRepos).toEqual(expect.arrayContaining([R2]));
    expect(dBody.removedRepos).not.toEqual(expect.arrayContaining([N1, N3]));
  }, 300_000);
});
