import { expect, test } from "bun:test";
import { createRecoverableStorage, draftStorage, preferenceStorage } from "../src/browser-storage";

class MemoryStorage {
  values = new Map<string, string>();
  getItem(key: string) { return this.values.get(key) ?? null; }
  setItem(key: string, value: string) { this.values.set(key, value); }
  removeItem(key: string) { this.values.delete(key); }
}

test("unavailable storage preserves a draft and consumes it once", () => {
  const storage = createRecoverableStorage(() => { throw new DOMException("Denied", "SecurityError"); });
  expect(storage.getItem("draft")).toBeNull();
  storage.setItem("draft", "retry this exact prompt");
  expect(storage.getItem("draft")).toBe("retry this exact prompt");
  storage.removeItem("draft");
  expect(storage.getItem("draft")).toBeNull();
});

test("healthy storage observes updates from another view", () => {
  const backend = new MemoryStorage();
  const storage = createRecoverableStorage(() => backend);
  storage.setItem("provider", "claude");
  expect(backend.getItem("provider")).toBe("claude");
  backend.setItem("provider", "codex");
  expect(storage.getItem("provider")).toBe("codex");
  storage.removeItem("provider");
  expect(backend.getItem("provider")).toBeNull();
});

test("a later denied read retains the last known preference", () => {
  const backend = new MemoryStorage();
  backend.setItem("cwd", "/work/project");
  let available = true;
  const storage = createRecoverableStorage(() => available ? backend : undefined);
  expect(storage.getItem("cwd")).toBe("/work/project");
  available = false;
  expect(storage.getItem("cwd")).toBe("/work/project");
});

test("failed writes win over stale disk data until a successful mutation", () => {
  const backend = new MemoryStorage();
  backend.setItem("draft", "old prompt");
  let writable = false;
  const storage = createRecoverableStorage(() => ({
    getItem: (key) => backend.getItem(key),
    setItem: (key, value) => {
      if (!writable) throw new DOMException("Full", "QuotaExceededError");
      backend.setItem(key, value);
    },
    removeItem: (key) => backend.removeItem(key),
  }));
  storage.setItem("draft", "recovered prompt");
  expect(storage.getItem("draft")).toBe("recovered prompt");
  expect(backend.getItem("draft")).toBe("old prompt");
  writable = true;
  storage.setItem("draft", "next prompt");
  expect(backend.getItem("draft")).toBe("next prompt");
  backend.setItem("draft", "another view's prompt");
  expect(storage.getItem("draft")).toBe("another view's prompt");
});

test("failed removal does not resurrect a consumed draft", () => {
  const backend = new MemoryStorage();
  backend.setItem("draft", "already consumed");
  const storage = createRecoverableStorage(() => ({
    getItem: (key) => backend.getItem(key),
    setItem: (key, value) => backend.setItem(key, value),
    removeItem() { throw new DOMException("Denied", "SecurityError"); },
  }));
  expect(storage.getItem("draft")).toBe("already consumed");
  storage.removeItem("draft");
  expect(storage.getItem("draft")).toBeNull();
  expect(storage.getItem("draft")).toBeNull();
  expect(backend.getItem("draft")).toBe("already consumed");
});

test("local preferences and session drafts keep separate fallbacks", () => {
  const previous = Object.getOwnPropertyDescriptors(globalThis);
  try {
    for (const name of ["localStorage", "sessionStorage"]) {
      Object.defineProperty(globalThis, name, {
        configurable: true,
        get() { throw new DOMException("Denied", "SecurityError"); },
      });
    }
    preferenceStorage.setItem("storage-test", "preference");
    draftStorage.setItem("storage-test", "draft");
    expect(preferenceStorage.getItem("storage-test")).toBe("preference");
    expect(draftStorage.getItem("storage-test")).toBe("draft");
  } finally {
    preferenceStorage.removeItem("storage-test");
    draftStorage.removeItem("storage-test");
    for (const name of ["localStorage", "sessionStorage"]) {
      if (previous[name]) Object.defineProperty(globalThis, name, previous[name]);
      else Reflect.deleteProperty(globalThis, name);
    }
  }
});
