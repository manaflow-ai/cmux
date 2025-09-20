import { readdirSync, rmSync } from "node:fs";
import { join } from "node:path";

import { ensureLogDirectory } from "./log-paths";

export function clearLogDirectory(): void {
  const dir = ensureLogDirectory();

  let entries: string[] = [];
  try {
    entries = readdirSync(dir);
  } catch {
    return;
  }

  for (const entry of entries) {
    const target = join(dir, entry);
    try {
      rmSync(target, { recursive: true, force: true });
    } catch {
      // ignore individual deletion errors
    }
  }
}
