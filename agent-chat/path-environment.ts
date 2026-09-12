/** Supplement minimal launchd environments without changing Windows search paths. */
export function initializeAgentPath(env: Record<string, string | undefined>, platform: NodeJS.Platform): void {
  // Windows uses semicolons and may spell the variable "Path". Leave it intact.
  if (platform === "win32") return;
  const home = env.HOME ?? "";
  const extra = [`${home}/.local/bin`, `${home}/.bun/bin`, "/opt/homebrew/bin", "/usr/local/bin"];
  const cur = env.PATH ? env.PATH.split(":") : [];
  env.PATH = [...extra.filter((p) => !cur.includes(p)), ...cur].join(":");
}
