import assert from "node:assert/strict";
import test from "node:test";
import { decodeBase64, encodeBase64 } from "../src/base64.js";

test("base64 uses browser globals when available", () => {
  const bytes = Uint8Array.from([0, 1, 2, 127, 128, 255]);
  assert.equal(encodeBase64(bytes), "AAECf4D/");
  assert.deepEqual(decodeBase64("AAECf4D/"), bytes);
});

test("base64 falls back to the Node Buffer global", () => {
  const atob = Object.getOwnPropertyDescriptor(globalThis, "atob");
  const btoa = Object.getOwnPropertyDescriptor(globalThis, "btoa");
  Object.defineProperty(globalThis, "atob", { configurable: true, value: undefined });
  Object.defineProperty(globalThis, "btoa", { configurable: true, value: undefined });
  try {
    const bytes = Uint8Array.from([27, 91, 63, 108]);
    assert.equal(encodeBase64(bytes), "G1s/bA==");
    assert.deepEqual(decodeBase64("G1s/bA=="), bytes);
  } finally {
    if (atob) Object.defineProperty(globalThis, "atob", atob);
    if (btoa) Object.defineProperty(globalThis, "btoa", btoa);
  }
});
