import { expect, test } from "bun:test";
import { AgentModelCatalogStore, mergeCatalogModels, validateAgentModelCatalog } from "../catalog";
import { mkdir, rm } from "node:fs/promises";
import { join } from "node:path";

const payload = {
  schemaVersion: 1,
  updatedAt: "2026-07-09T00:00:00Z",
  providers: {
    claude: {
      defaultModel: "claude-new",
      models: [
        { id: "claude-new", label: "Claude New", minVersion: "3.0.0", supportsOneMillion: true },
        { id: "broken" },
      ],
    },
    codex: {
      defaultModel: "gpt-new",
      models: [{ id: "gpt-new", label: "GPT New", description: "Remote label wins" }],
    },
  },
} as const;

test("model catalog validation, persistence, ETag, and layering", async () => {
  expect(() => validateAgentModelCatalog({ ...payload, schemaVersion: 2 })).toThrow("unsupported");
  const parsed = validateAgentModelCatalog(payload);
  expect(parsed.providers.claude?.models).toHaveLength(1);
  expect(parsed.providers.claude?.models[0]?.id).toBe("claude-new");

  const root = join(import.meta.dir, "..", "scratch", "catalog-test");
  const cacheFile = join(root, "models.json");
  await rm(root, { recursive: true, force: true });
  await mkdir(root, { recursive: true });

  let requests = 0;
  let sawEtag = false;
  let mode: "payload" | "not-modified" | "bad" = "payload";
  const fixture = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(req) {
      requests += 1;
      sawEtag ||= req.headers.get("if-none-match") === '"v1"';
      if (mode === "not-modified") return new Response(null, { status: 304, headers: { etag: '"v1"' } });
      if (mode === "bad") return Response.json({ ...payload, schemaVersion: 99 });
      return Response.json(payload, { headers: { etag: '"v1"' } });
    },
  });

  let now = 1_000;
  try {
    const store = new AgentModelCatalogStore({
      url: `http://127.0.0.1:${fixture.port}/catalog`,
      cacheFile,
      ttlMs: 100,
      now: () => now,
    });
    expect(store.hasPayload).toBe(false);
    expect(await store.refresh()).toBe(true);
    expect(store.provider("claude")?.defaultModel).toBe("claude-new");

    const offline = new AgentModelCatalogStore({
      url: "http://127.0.0.1:1/unavailable",
      cacheFile,
      now: () => now,
    });
    expect(offline.provider("codex")?.models[0]?.label).toBe("GPT New");

    mode = "bad";
    await expect(store.refresh()).rejects.toThrow("unsupported");
    expect(store.provider("claude")?.defaultModel).toBe("claude-new");

    mode = "not-modified";
    now += 200;
    expect(store.isStale()).toBe(true);
    expect(await store.refresh()).toBe(false);
    expect(sawEtag).toBe(true);
    expect(store.isStale()).toBe(false);
    expect(requests).toBe(3);
  } finally {
    fixture.stop(true);
  }

  const remote = parsed.providers.codex;
  const binary = [
    { id: "gpt-new", label: "raw slug", source: "binary" },
    { id: "binary-only", label: "Binary Only", source: "binary" },
  ];
  const fallback = [{ id: "built-in", label: "Built In", source: "fallback" }];
  const merged = mergeCatalogModels(remote, binary, fallback, true, (model) => ({
    id: model.id,
    label: model.label,
    source: "remote",
  }));
  expect(merged.map((model) => model.id)).toEqual(["gpt-new", "binary-only"]);
  expect(merged[0]?.label).toBe("GPT New");
  expect(merged[1]?.source).toBe("binary");

  const offlineMerged = mergeCatalogModels(undefined, binary, fallback, false, (model) => ({
    id: model.id,
    label: model.label,
    source: "remote",
  }));
  expect(offlineMerged.map((model) => model.id)).toEqual(["built-in", "gpt-new", "binary-only"]);
});
