import { describe, expect, it, vi } from "vitest";
import { runWithAuthToken, getAuthToken } from "./requestContext.js";

vi.mock("convex/browser", () => {
  const ConvexHttpClient = vi
    .fn()
    .mockImplementation((url: string, options?: { auth?: string }) => ({
      __url: url,
      __options: options ?? {},
    }));
  return { ConvexHttpClient };
});

describe("requestContext + getConvex wrapper", () => {
  it("propagates auth token via AsyncLocalStorage", () => {
    expect(getAuthToken()).toBeUndefined();
    const value = runWithAuthToken("abc123", () => getAuthToken());
    expect(value).toBe("abc123");
  });

  it("passes auth token into ConvexHttpClient options", async () => {
    const { getConvex, CONVEX_URL } = await import("./convexClient.js");

    // Without context, no auth option
    const c1 = getConvex() as unknown as { __url: string; __options: { auth?: string } };
    expect(c1.__url).toBe(CONVEX_URL);
    expect(c1.__options.auth).toBeUndefined();

    // With context, auth should be set
    const c2 = runWithAuthToken("jwt-token", () =>
      getConvex() as unknown as { __url: string; __options: { auth?: string } }
    );
    expect(c2.__url).toBe(CONVEX_URL);
    expect(c2.__options.auth).toBe("jwt-token");
  });

  it("preserves token across async boundaries", async () => {
    const { getConvex } = await import("./convexClient.js");
    await new Promise<void>((resolve) => {
      runWithAuthToken("async-token", async () => {
        await new Promise((r) => setTimeout(r, 0));
        const client = getConvex() as unknown as { __options: { auth?: string } };
        expect(client.__options.auth).toBe("async-token");
        resolve();
      });
    });
  });

  it("isolates tokens across concurrent contexts", async () => {
    const { getConvex } = await import("./convexClient.js");

    const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

    const results: Array<{ a?: string; b?: string }> = [];

    const taskA = runWithAuthToken("token-A", async () => {
      await sleep(10);
      const cA1 = getConvex() as unknown as { __options: { auth?: string } };
      results.push({ a: cA1.__options.auth });
      await sleep(5);
      const cA2 = getConvex() as unknown as { __options: { auth?: string } };
      results.push({ a: cA2.__options.auth });
    });

    const taskB = runWithAuthToken("token-B", async () => {
      const cB1 = getConvex() as unknown as { __options: { auth?: string } };
      results.push({ b: cB1.__options.auth });
      await sleep(15);
      const cB2 = getConvex() as unknown as { __options: { auth?: string } };
      results.push({ b: cB2.__options.auth });
    });

    await Promise.all([taskA, taskB]);

    // Validate that each recorded token corresponds to its own context only
    for (const r of results) {
      if (r.a !== undefined) {
        expect(r.a).toBe("token-A");
      }
      if (r.b !== undefined) {
        expect(r.b).toBe("token-B");
      }
    }

    // Outside any context, token should be undefined
    expect(getAuthToken()).toBeUndefined();
  });

  it("restores parent token after nested context exits", async () => {
    const { getConvex } = await import("./convexClient.js");

    await runWithAuthToken("parent-token", async () => {
      // Parent
      const parentClient = getConvex() as unknown as { __options: { auth?: string } };
      expect(parentClient.__options.auth).toBe("parent-token");

      // Nested override
      await runWithAuthToken("child-token", async () => {
        const childClient = getConvex() as unknown as { __options: { auth?: string } };
        expect(childClient.__options.auth).toBe("child-token");
      });

      // Back to parent after nested completes
      const afterClient = getConvex() as unknown as { __options: { auth?: string } };
      expect(afterClient.__options.auth).toBe("parent-token");
    });
  });
});
