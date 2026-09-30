import {
  normalizeProviderOptionStore,
  readStoredProviderOptions,
  updateStoredProviderOption,
} from "../src/options-store";
import type { SessionOption } from "../src/session";

class MemoryStorage {
  private values = new Map<string, string>();
  getItem(key: string) { return this.values.get(key) ?? null; }
  setItem(key: string, value: string) { this.values.set(key, value); }
}

const options = (model: string): SessionOption[] => [
  { id: "model", label: "Model", kind: "select", value: model, choices: [{ value: "m1", label: "M1" }, { value: "m2", label: "M2" }] },
  { id: "effort", label: "Effort", kind: "select", role: "effort", value: "medium", choices: [{ value: "low", label: "Low" }, { value: "high", label: "High" }] },
  { id: "context", label: "Context", kind: "select", role: "context", value: "200k", choices: [{ value: "200k", label: "200k" }, { value: "1m", label: "1M" }] },
  { id: "fastMode", label: "Fast", kind: "toggle", value: false },
  { id: "permissionMode", label: "Mode", kind: "select", value: "default", choices: [{ value: "default", label: "Default" }, { value: "plan", label: "Plan" }] },
];

const migrated = normalizeProviderOptionStore({ model: "m1", effort: "high", context: "1m", fastMode: true, permissionMode: "plan" });
if (migrated.model !== "m1") throw new Error("legacy model did not migrate");
if (migrated.models.m1?.effort !== "high" || migrated.models.m1?.context !== "1m" || migrated.models.m1?.fastMode !== true) {
  throw new Error(`legacy model-scoped values did not migrate: ${JSON.stringify(migrated)}`);
}
if (migrated.harness.permissionMode !== "plan") throw new Error("legacy harness-scoped value did not migrate");

const storage = new MemoryStorage();
let flat = updateStoredProviderOption("codex", "model", "m1", options("m1"), storage);
flat = updateStoredProviderOption("codex", "effort", "high", options("m1"), storage);
flat = updateStoredProviderOption("codex", "context", "1m", options("m1"), storage);
flat = updateStoredProviderOption("codex", "permissionMode", "plan", options("m1"), storage);
if (flat.model !== "m1" || flat.effort !== "high" || flat.context !== "1m" || flat.permissionMode !== "plan") {
  throw new Error(`m1 restore failed: ${JSON.stringify(flat)}`);
}

flat = updateStoredProviderOption("codex", "model", "m2", options("m1"), storage);
if (flat.model !== "m2" || flat.effort !== undefined || flat.context !== undefined || flat.permissionMode !== "plan") {
  throw new Error(`model switch should restore only harness values for m2: ${JSON.stringify(flat)}`);
}

flat = updateStoredProviderOption("codex", "effort", "low", options("m2"), storage);
if (flat.model !== "m2" || flat.effort !== "low") throw new Error(`m2 scoped effort failed: ${JSON.stringify(flat)}`);

flat = updateStoredProviderOption("codex", "model", "m1", options("m2"), storage);
if (flat.model !== "m1" || flat.effort !== "high" || flat.context !== "1m" || flat.permissionMode !== "plan") {
  throw new Error(`m1 scoped values were not restored: ${JSON.stringify(flat)}`);
}

const read = readStoredProviderOptions("codex", storage);
if (read.model !== "m1" || read.effort !== "high" || read.permissionMode !== "plan") {
  throw new Error(`read round trip failed: ${JSON.stringify(read)}`);
}

console.log("options store assertions passed");
