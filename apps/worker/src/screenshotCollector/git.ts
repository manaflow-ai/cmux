import { runCommandCapture } from "../crown/utils";

export function extractPathFromDiff(rawPath: string): string {
  const trimmed = rawPath.trim();
  const arrowIndex = trimmed.indexOf(" => ");
  if (arrowIndex === -1) {
    return trimmed;
  }

  const braceStart = trimmed.indexOf("{");
  const braceEnd = trimmed.indexOf("}");
  if (
    braceStart !== -1 &&
    braceEnd !== -1 &&
    braceEnd > braceStart &&
    braceStart < arrowIndex &&
    braceEnd > arrowIndex
  ) {
    const prefix = trimmed.slice(0, braceStart);
    const braceContent = trimmed.slice(braceStart + 1, braceEnd);
    const suffix = trimmed.slice(braceEnd + 1);
    const braceParts = braceContent.split(" => ");
    const replacement = braceParts[braceParts.length - 1] ?? "";
    return `${prefix}${replacement}${suffix}`;
  }

  const parts = trimmed.split(" => ");
  return parts[parts.length - 1] ?? trimmed;
}

export function parseFileList(raw: string): string[] {
  return raw
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.length > 0);
}

export async function filterTextFiles(
  workspaceDir: string,
  baseRevision: string,
  files: readonly string[]
): Promise<string[]> {
  if (files.length === 0) {
    return [];
  }

  const fileSet = new Set(files);
  const args = ["diff", "--numstat", `${baseRevision}..HEAD`, "--", ...files];

  const output = await runCommandCapture("git", args, { cwd: workspaceDir });
  const textFiles = new Set<string>();

  output.split("\n").forEach((line) => {
    if (!line.trim()) {
      return;
    }
    const parts = line.split("\t");
    if (parts.length < 3) {
      return;
    }
    const [addedRaw, deletedRaw, ...pathParts] = parts;
    if (!addedRaw || !deletedRaw || pathParts.length === 0) {
      return;
    }
    const added = addedRaw.trim();
    const deleted = deletedRaw.trim();
    if (added === "-" || deleted === "-") {
      // Binary diff shows "-" for text stats.
      return;
    }
    const rawPath = pathParts.join("\t").trim();
    if (!rawPath) {
      return;
    }
    const normalizedPath = extractPathFromDiff(rawPath);
    if (fileSet.has(normalizedPath)) {
      textFiles.add(normalizedPath);
      return;
    }
    if (fileSet.has(rawPath)) {
      textFiles.add(rawPath);
      return;
    }
    textFiles.add(normalizedPath);
  });

  return files.filter((file) => textFiles.has(file));
}

export async function detectRemoteHead(
  workspaceDir: string
): Promise<string> {
  try {
    const symbolicRefRaw = await runCommandCapture(
      "git",
      ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
      { cwd: workspaceDir }
    );
    const symbolicRef = symbolicRefRaw.split("\n")[0]?.trim();
    if (symbolicRef) {
      return symbolicRef;
    }
  } catch {
    // Fall back to parsing remote show output.
  }

  try {
    const remoteInfo = await runCommandCapture(
      "git",
      ["remote", "show", "origin"],
      { cwd: workspaceDir }
    );
    for (const line of remoteInfo.split("\n")) {
      const trimmed = line.trim();
      if (trimmed.startsWith("HEAD branch:")) {
        const branchName = trimmed.slice("HEAD branch:".length).trim();
        if (branchName) {
          return `origin/${branchName}`;
        }
      }
    }
  } catch {
    // Swallow and throw below with unified error.
  }

  throw new Error(
    "Unable to determine remote HEAD branch from origin (no symbolic ref or HEAD branch information)"
  );
}

export async function resolveMergeBase(
  workspaceDir: string
): Promise<{ baseBranch: string; mergeBase: string }> {
  const baseBranch = await detectRemoteHead(workspaceDir);
  const mergeBaseRaw = await runCommandCapture(
    "git",
    ["merge-base", "HEAD", baseBranch],
    { cwd: workspaceDir }
  );
  const mergeBase = mergeBaseRaw.split("\n")[0]?.trim();
  if (!mergeBase) {
    throw new Error(
      `Unable to determine merge base between HEAD and ${baseBranch}`
    );
  }
  return { baseBranch, mergeBase };
}
