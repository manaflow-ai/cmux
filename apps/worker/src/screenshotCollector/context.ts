import { promises as fs } from "node:fs";
import { join } from "node:path";

const PR_DESCRIPTION_RELATIVE_PATH = ".cmux/pr-description.md";

interface NodeError extends Error {
  code?: string;
}

function isNodeError(error: unknown): error is NodeError {
  return error instanceof Error && "code" in error;
}

export async function readPrDescription(
  workspaceDir: string
): Promise<string | null> {
  const filePath = join(workspaceDir, PR_DESCRIPTION_RELATIVE_PATH);
  try {
    const content = await fs.readFile(filePath, { encoding: "utf8" });
    return content.trim().length > 0 ? content : null;
  } catch (error: unknown) {
    if (isNodeError(error) && error.code === "ENOENT") {
      return null;
    }
    throw error;
  }
}
