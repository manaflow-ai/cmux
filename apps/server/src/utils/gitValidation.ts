const COMMIT_SHA_REGEX = /^[0-9a-f]{7,64}$/i;
const SAFE_REF_REGEX = /^[A-Za-z0-9_][A-Za-z0-9._/-]*$/;

const INVALID_REF_SUBSTRINGS = [
  "..",
  "@{",
  "\\",
  "~",
  "^",
  ":",
  "?",
  "*",
  "[",
  " ",
  "\t",
  "\n",
  "\r",
];

const GITHUB_SSH_REGEX =
  /^git@github\.com:([A-Za-z0-9_-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?$/i;

const GITHUB_PATH_REGEX =
  /^\/([A-Za-z0-9_-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?\/?$/;

export function isSafeGitRef(ref: string): boolean {
  if (ref.length === 0) return false;
  if (ref.trim() !== ref) return false;
  if (ref.includes("\0")) return false;

  if (COMMIT_SHA_REGEX.test(ref)) {
    return true;
  }

  if (!SAFE_REF_REGEX.test(ref)) return false;
  if (ref.startsWith("-") || ref.startsWith(".") || ref.startsWith("/")) {
    return false;
  }
  if (ref.endsWith("/") || ref.endsWith(".") || ref.endsWith(".lock")) {
    return false;
  }
  if (ref.includes("//") || ref.includes("/.") || ref.includes("..")) {
    return false;
  }

  if (INVALID_REF_SUBSTRINGS.some((substr) => ref.includes(substr))) {
    return false;
  }

  return true;
}

export function assertSafeGitRef(ref: string, label: string): void {
  if (!isSafeGitRef(ref)) {
    throw new Error(`Unsafe git ref for ${label}`);
  }
}

export function isSafeGitRemoteUrl(repoUrl: string): boolean {
  if (!repoUrl) return false;
  if (repoUrl.trim() !== repoUrl) return false;
  if (repoUrl.includes("\0")) return false;
  if (/\s/.test(repoUrl)) return false;
  if (repoUrl.startsWith("-")) return false;

  if (GITHUB_SSH_REGEX.test(repoUrl)) {
    return true;
  }

  let parsed: URL;
  try {
    parsed = new URL(repoUrl);
  } catch {
    return false;
  }

  if (parsed.protocol !== "https:") {
    return false;
  }
  if (parsed.hostname.toLowerCase() !== "github.com") {
    return false;
  }

  return GITHUB_PATH_REGEX.test(parsed.pathname);
}

export function assertSafeGitRemoteUrl(repoUrl: string, label: string): void {
  if (!isSafeGitRemoteUrl(repoUrl)) {
    throw new Error(`Unsafe git remote URL for ${label}`);
  }
}
