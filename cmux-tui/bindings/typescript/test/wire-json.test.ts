import assert from "node:assert/strict";
import test from "node:test";
import { parseWireJson, stringifyWireJson } from "../src/wire-json.js";

test("wire JSON round-trips the full uint64 range without number rounding", () => {
  const maximum = 18_446_744_073_709_551_615n;
  const encoded = stringifyWireJson({ surface: maximum, safe: 42 });
  assert.equal(encoded, '{"surface":18446744073709551615,"safe":42}');
  assert.deepEqual(parseWireJson(encoded), { surface: maximum, safe: 42 });
});

test("wire JSON rejects unsafe number integers", () => {
  assert.throws(
    () => stringifyWireJson({ surface: Number.MAX_SAFE_INTEGER + 1 }),
    /unsafe integer number/,
  );
});

test("wire JSON preserves missing fields separately from null", () => {
  const encoded = stringifyWireJson({ missing: undefined, nullable: null });
  assert.equal(encoded, '{"nullable":null}');
  assert.deepEqual(parseWireJson(encoded), { nullable: null });
});

test("wire JSON bounds recursive nesting", () => {
  assert.throws(() => parseWireJson("[[[0]]]", 2), /nesting exceeds 2/);
  assert.throws(() => stringifyWireJson([[[0]]], 2), /nesting exceeds 2/);
});
