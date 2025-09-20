import { readdir, readFile, stat } from "node:fs/promises";
import { join } from "node:path";

import { ensureLogDirectory } from "./log-paths";

export interface CollectedLogFile {
  name: string;
  path: string;
  size: number;
  modifiedMs: number | null;
  content: string;
}

export interface CollectedLogsBundle {
  files: CollectedLogFile[];
  combinedText: string;
}

function buildCombinedText(files: CollectedLogFile[]): string {
  if (files.length === 0) {
    return "";
  }

  return files
    .map((file) => {
      const headerLines = [
        `===== ${file.name} =====`,
        file.modifiedMs
          ? `Last modified: ${new Date(file.modifiedMs).toISOString()}`
          : "Last modified: unknown",
        "",
      ];
      return `${headerLines.join("\n")}${file.content}`;
    })
    .join("\n\n");
}

export async function collectAllLogs(): Promise<CollectedLogsBundle> {
  const dir = ensureLogDirectory();
  let entries: Awaited<ReturnType<typeof readdir>> | undefined;

  try {
    entries = await readdir(dir, { withFileTypes: true });
  } catch {
    // If the directory can't be read, return an empty bundle.
    return { files: [], combinedText: "" };
  }

  const files: CollectedLogFile[] = [];

  for (const entry of entries) {
    if (!entry.isFile()) continue;

    const filePath = join(dir, entry.name);
    let size = 0;
    let modifiedMs: number | null = null;
    let content = "";

    try {
      const stats = await stat(filePath);
      size = stats.size;
      modifiedMs = Number.isFinite(stats.mtimeMs) ? stats.mtimeMs : null;
    } catch {
      // Ignore stat errors but continue reading content if possible.
    }

    try {
      content = await readFile(filePath, { encoding: "utf8" });
    } catch (error) {
      const err = error instanceof Error ? error.message : String(error);
      content = `[Failed to read log file: ${err}]`;
    }

    files.push({
      name: entry.name,
      path: filePath,
      size,
      modifiedMs,
      content,
    });
  }

  files.sort((a, b) => {
    const modA = a.modifiedMs ?? 0;
    const modB = b.modifiedMs ?? 0;
    if (modA !== modB) return modB - modA;
    return a.name.localeCompare(b.name);
  });

  return {
    files,
    combinedText: buildCombinedText(files),
  };
}
