import type { OptionValue, SessionOption } from "./session";

export interface ProviderOptionStore {
  version: 2;
  model?: string;
  harness: Record<string, OptionValue>;
  models: Record<string, Record<string, OptionValue>>;
}

interface StorageLike {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
}

const MODEL_SCOPED = new Set(["effort", "context", "fastMode"]);

function key(provider: string): string {
  return `agentui.opts.${provider}`;
}

export function isModelScopedOption(id: string): boolean {
  return MODEL_SCOPED.has(id);
}

function emptyStore(): ProviderOptionStore {
  return { version: 2, harness: {}, models: {} };
}

function primitiveRecord(value: unknown): Record<string, OptionValue> {
  const out: Record<string, OptionValue> = {};
  if (!value || typeof value !== "object") return out;
  for (const [k, v] of Object.entries(value as Record<string, unknown>)) {
    if (typeof v === "string" || typeof v === "boolean") out[k] = v;
  }
  return out;
}

export function normalizeProviderOptionStore(raw: unknown): ProviderOptionStore {
  const store = emptyStore();
  if (!raw || typeof raw !== "object") return store;
  const obj = raw as Record<string, unknown>;
  if (obj.version === 2) {
    if (typeof obj.model === "string") store.model = obj.model;
    store.harness = primitiveRecord(obj.harness);
    const models = obj.models;
    if (models && typeof models === "object") {
      for (const [model, values] of Object.entries(models as Record<string, unknown>)) {
        const rec = primitiveRecord(values);
        if (Object.keys(rec).length) store.models[model] = rec;
      }
    }
    return store;
  }

  const legacy = primitiveRecord(obj);
  if (typeof legacy.model === "string" && legacy.model) store.model = legacy.model;
  for (const [id, value] of Object.entries(legacy)) {
    if (id === "model") continue;
    if (isModelScopedOption(id) && store.model) {
      store.models[store.model] = { ...(store.models[store.model] ?? {}), [id]: value };
    } else {
      store.harness[id] = value;
    }
  }
  return store;
}

export function flatOptionsFromStore(store: ProviderOptionStore): Record<string, OptionValue> {
  const out: Record<string, OptionValue> = { ...store.harness };
  if (store.model) {
    out.model = store.model;
    Object.assign(out, store.models[store.model] ?? {});
  }
  return out;
}

export function readStoredProviderOptions(provider: string, storage: StorageLike = localStorage): Record<string, OptionValue> {
  try {
    return flatOptionsFromStore(normalizeProviderOptionStore(JSON.parse(storage.getItem(key(provider)) || "null")));
  } catch {
    return {};
  }
}

export function readProviderOptionStore(provider: string, storage: StorageLike = localStorage): ProviderOptionStore {
  try {
    return normalizeProviderOptionStore(JSON.parse(storage.getItem(key(provider)) || "null"));
  } catch {
    return emptyStore();
  }
}

export function writeProviderOptionStore(provider: string, store: ProviderOptionStore, storage: StorageLike = localStorage) {
  storage.setItem(key(provider), JSON.stringify(store));
}

function optionModel(options: SessionOption[], fallback?: string): string | undefined {
  const value = options.find((o) => o.id === "model")?.value;
  return typeof value === "string" && value ? value : fallback;
}

export function updateStoredProviderOption(
  provider: string,
  id: string,
  value: OptionValue,
  options: SessionOption[],
  storage: StorageLike = localStorage,
): Record<string, OptionValue> {
  const store = readProviderOptionStore(provider, storage);
  const activeModel = id === "model" && typeof value === "string" ? value : optionModel(options, store.model);
  if (id === "model") {
    if (typeof value === "string" && value) store.model = value;
    else delete store.model;
  } else if (isModelScopedOption(id) && activeModel) {
    store.models[activeModel] = { ...(store.models[activeModel] ?? {}), [id]: value };
  } else {
    store.harness[id] = value;
  }
  writeProviderOptionStore(provider, store, storage);
  return flatOptionsFromStore(store);
}

export function writeStoredProviderOptions(
  provider: string,
  values: Record<string, OptionValue>,
  options: SessionOption[] = [],
  storage: StorageLike = localStorage,
): Record<string, OptionValue> {
  const store = readProviderOptionStore(provider, storage);
  const model = typeof values.model === "string" && values.model ? values.model : optionModel(options, store.model);
  if (model) store.model = model;
  for (const [id, value] of Object.entries(values)) {
    if (id === "model") continue;
    if (isModelScopedOption(id) && model) {
      store.models[model] = { ...(store.models[model] ?? {}), [id]: value };
    } else {
      store.harness[id] = value;
    }
  }
  writeProviderOptionStore(provider, store, storage);
  return flatOptionsFromStore(store);
}

export function persistOptionsSnapshot(provider: string, options: SessionOption[], storage: StorageLike = localStorage) {
  const values: Record<string, OptionValue> = {};
  for (const option of options) values[option.id] = option.value;
  writeStoredProviderOptions(provider, values, options, storage);
}
