import type { NodeClient } from "../src/node.js";
import type { CloudClient } from "./cloud.js";

declare global {
  /** Catalog-gated cmux resource client injected by `cmux run`. */
  const cmux: NodeClient;
  /** Arguments after the script path. */
  const cmuxArgs: readonly string[];
  /** Host-owned typed Cloud relay. Undefined when the host is not authenticated. */
  const cmuxCloud: CloudClient | undefined;
}

export {};
