import { expect, test } from "bun:test";
import { AgentModelCatalogStore, mergeCatalogModels, selectEnabledModel, validateAgentModelCatalog } from "../catalog";
import { mergeAcpModelOption } from "../adapters/acp";
import { mergeCodexModels } from "../adapters/codex";
import { mergeRemoteModelOptionsForTest } from "../server";
import { mkdir, rm } from "node:fs/promises";
import { join } from "node:path";

const payload = {
  schemaVersion: 1,
  updatedAt: "2026-07-09T00:00:00Z",
  providers: {
    claude: {
      defaultModel: "filtered-out",
      models: [
        { id: "claude-new", label: "Claude New", minVersion: "3.0.0", supportsOneMillion: true },
        { id: "broken" },
      ],
    },
    codex: {
      defaultModel: "gpt-new",
      models: [{
        id: "gpt-new",
        label: "GPT New",
        description: "Remote description",
        contextWindow: 400000,
        efforts: [
          { value: "none", label: "none" },
          { value: "xhigh", label: "Extra high", description: "Remote effort" },
        ],
        defaultEffort: "xhigh",
        serviceTiers: [{ id: "priority", name: "Priority", description: "Remote tier" }],
        defaultServiceTier: "priority",
      }],
    },
  },
} as const;

test("catalog validation, provider merges, persistence, and ETag", async () => {
  expect(() => validateAgentModelCatalog({ ...payload, schemaVersion: 2 })).toThrow("unsupported");
  const parsed = validateAgentModelCatalog(payload);
  expect(parsed.providers.claude?.models).toHaveLength(1);
  expect(parsed.providers.claude?.defaultModel).toBe("claude-new");

  const acp = mergeAcpModelOption(
    { id: "model", label: "Model", kind: "select", value: "binary-current", choices: [{ value: "binary-listed", label: "Binary Listed" }] },
    [{ value: "remote", label: "Remote" }],
    "remote",
  );
  expect(acp.value).toBe("binary-current");
  expect(acp.choices?.map((choice) => choice.value)).toEqual(["remote", "binary-listed", "binary-current"]);

  const remoteCodex = parsed.providers.codex!;
  const codex = mergeCodexModels([{
    value: "gpt-new",
    label: "Binary Label",
    description: "Binary description",
    efforts: [{ value: "high", label: "high" }],
    defaultEffort: "high",
    serviceTiers: [{ id: "fast", name: "Fast" }],
    defaultServiceTier: null,
  }], remoteCodex);
  expect(codex[0]?.label).toBe("GPT New");
  expect(codex[0]?.description).toBe("Remote description");
  expect(codex[0]?.contextWindow).toBe(400000);
  expect(codex[0]?.efforts.map((effort) => effort.value)).toEqual(["xhigh"]);
  expect(codex[0]?.defaultEffort).toBe("xhigh");
  expect(codex[0]?.serviceTiers[0]?.id).toBe("priority");
  expect(codex[0]?.defaultServiceTier).toBe("priority");

  const remoteOnly = mergeCodexModels([], remoteCodex)[0]!;
  expect(remoteOnly.efforts.map((effort) => effort.value)).toEqual(["xhigh"]);
  expect(remoteOnly.defaultEffort).toBe("xhigh");
  expect(remoteOnly.serviceTiers[0]?.name).toBe("Priority");

  const catchOptions = mergeRemoteModelOptionsForTest("codex", [
    { id: "model", label: "Model", kind: "select", value: "", choices: [] },
    { id: "effort", label: "Effort", kind: "select", value: "medium", choices: [{ value: "medium", label: "medium" }] },
  ], remoteCodex);
  const catchModel = catchOptions.find((option) => option.id === "model");
  expect(catchModel?.value).toBe("gpt-new");
  expect(catchModel?.choices?.map((choice) => choice.value)).toContain("gpt-new");

  expect(selectEnabledModel("gated", [
    { id: "gated", disabled: true },
    { id: "supported", disabled: false },
  ])).toBe("supported");

  const merged = mergeCatalogModels(
    remoteCodex,
    [{ id: "gpt-new", label: "Binary" }, { id: "binary-only", label: "Binary Only" }],
    [{ id: "built-in", label: "Built In" }],
    true,
    (model) => ({ id: model.id, label: model.label }),
  );
  expect(merged.map((model) => model.id)).toEqual(["gpt-new", "binary-only"]);
  expect(merged[0]?.label).toBe("GPT New");

  const root = join(import.meta.dir, "..", "scratch", "catalog-test");
  const cacheFile = join(root, "models.json");
  await rm(root, { recursive: true, force: true });
  await mkdir(root, { recursive: true });
  let mode: "payload" | "not-modified" | "bad" = "payload";
  let sawEtag = false;
  const fixture = Bun.serve({
    port: 0,
    hostname: "127.0.0.1",
    fetch(req) {
      sawEtag ||= req.headers.get("if-none-match") === '"v1"';
      if (mode === "not-modified") return new Response(null, { status: 304 });
      if (mode === "bad") return Response.json({ ...payload, schemaVersion: 99 });
      return Response.json(payload, { headers: { etag: '"v1"' } });
    },
  });
  let now = 1_000;
  try {
    const store = new AgentModelCatalogStore({ url: `http://127.0.0.1:${fixture.port}`, cacheFile, ttlMs: 100, now: () => now });
    expect(await store.refresh()).toBe(true);
    const offline = new AgentModelCatalogStore({ url: "http://127.0.0.1:1", cacheFile });
    expect(offline.provider("codex")?.models[0]?.label).toBe("GPT New");
    mode = "bad";
    await expect(store.refresh()).rejects.toThrow("unsupported");
    expect(store.provider("codex")?.models[0]?.label).toBe("GPT New");
    mode = "not-modified";
    now += 200;
    expect(await store.refreshIfStale()).toBe(false);
    expect(sawEtag).toBe(true);
  } finally {
    fixture.stop(true);
  }
});
