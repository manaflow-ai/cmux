import type { NodeClient } from "../src/node.js";

declare global {
  /** Catalog-gated cmux resource client injected by `cmux run`. */
  const cmux: NodeClient;
  /** Arguments after the script path. */
  const cmuxArgs: readonly string[];
}

export {};
