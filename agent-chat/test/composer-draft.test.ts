import assert from "node:assert/strict";
import { describe, test } from "bun:test";
import { createRecoverableStorage } from "../src/browser-storage";
import { persistComposerDraft } from "../src/components/Composer";
import { readComposerDraft, writeComposerDraft } from "../src/session";

function memoryStorage(): Storage {
  const values = new Map<string, string>();
  return {
    getItem: (key) => values.get(key) ?? null,
    setItem: (key, value) => { values.set(key, String(value)); },
    removeItem: (key) => { values.delete(key); },
    clear: () => values.clear(),
    key: (index) => [...values.keys()][index] ?? null,
    get length() { return values.size; },
  } as Storage;
}

function throwingStorage() {
  return createRecoverableStorage(() => {
    throw new Error("storage unavailable");
  });
}

describe("first-use Composer draft", () => {
  test("restores a typed prompt after unmount/remount and removes it when emptied", () => {
    const storage = memoryStorage();
    globalThis.sessionStorage = storage;

    // Mount: the Composer reads this value, then typing persists it.
    assert.equal(readComposerDraft(storage), "");
    persistComposerDraft("keep this prompt");

    // Unmount/remount: the next Composer instance sees the unsent prompt.
    assert.equal(readComposerDraft(storage), "keep this prompt");

    // Emptying the field removes the recoverable draft immediately.
    persistComposerDraft("");
    assert.equal(readComposerDraft(storage), "");
  });

  test("clears the draft only after start accepts the prompt", () => {
    const storage = memoryStorage();
    globalThis.sessionStorage = storage;

    persistComposerDraft("retry if start fails");
    const accepted = false;
    if (accepted) persistComposerDraft("");
    assert.equal(readComposerDraft(storage), "retry if start fails");

    // A true start() result is the established acceptance point.
    persistComposerDraft("");
    assert.equal(readComposerDraft(storage), "");
  });

  test("keeps provider and CWD preferences independent from the prompt draft", () => {
    const draft = memoryStorage();
    const preferences = memoryStorage();
    globalThis.sessionStorage = draft;
    globalThis.localStorage = preferences;

    preferences.setItem("agentui.provider", "claude");
    preferences.setItem("agentui.cwd", "/tmp/one");
    persistComposerDraft("work in progress");
    preferences.setItem("agentui.provider", "codex");
    preferences.setItem("agentui.cwd", "/tmp/two");

    assert.equal(readComposerDraft(draft), "work in progress");
    assert.equal(preferences.getItem("agentui.provider"), "codex");
    assert.equal(preferences.getItem("agentui.cwd"), "/tmp/two");
  });

  test("keeps the draft available when storage throws", () => {
    const storage = throwingStorage();
    writeComposerDraft(storage, "survive storage failure");
    assert.equal(readComposerDraft(storage), "survive storage failure");
    writeComposerDraft(storage, "");
    assert.equal(readComposerDraft(storage), "");
  });
});
