/**
 * Conformance vectors for every feed owner (plans/cmux-next/feed.md step F4):
 * the cloud FeedDO reducer and the local feed server (Rust `cmux-feed-core`)
 * must give the same result code, value and final state for each step.
 *
 *   bun scripts/feed-vectors.ts          write backend/catalog/feed-vectors.json
 *   bun scripts/feed-vectors.ts --check  fail when the checked-in file differs
 */
import { readFileSync, writeFileSync } from "node:fs"
import { fileURLToPath } from "node:url"
import { canonicalJson } from "@cmux/ownership"
import { buildVectors } from "../test/feed-vector-cases.ts"

const path = fileURLToPath(new URL("../../../catalog/feed-vectors.json", import.meta.url))
const text = `${JSON.stringify(JSON.parse(canonicalJson(buildVectors())), null, 1)}\n`
if (process.argv.includes("--check")) {
  if (readFileSync(path, "utf8") !== text) {
    console.error("catalog/feed-vectors.json is stale: run bun scripts/feed-vectors.ts")
    process.exit(1)
  }
} else writeFileSync(path, text)
