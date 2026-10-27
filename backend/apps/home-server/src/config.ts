import { existsSync, mkdirSync, readFileSync, statSync, writeFileSync } from "node:fs"
import { homedir, platform } from "node:os"
import { dirname, join } from "node:path"
import type { AccessConfig } from "./admission.ts"

/** The default port of a self-hosted chat server (remote hosts use 7319). */
export const DEFAULT_PORT = 7320

/** `<data>/config.json`: who may connect, and the port. */
export interface ServerConfig extends AccessConfig {
  readonly port: number
}

/** The data directory: macOS Application Support, Linux XDG state. */
export const defaultDataDir = (): string =>
  platform() === "darwin" ? join(homedir(), "Library", "Application Support", "cmux", "chat-server") : join(process.env.XDG_STATE_HOME || join(homedir(), ".local", "state"), "cmux", "chat-server")

export const configPath = (dataDir: string) => join(dataDir, "config.json")

export const readConfig = (dataDir: string): ServerConfig | null => {
  const file = configPath(dataDir)
  if (!existsSync(file)) return null
  const j = JSON.parse(readFileSync(file, "utf8")) as Partial<ServerConfig>
  if (typeof j.owner !== "string" || !j.owner) return null
  return { owner: j.owner.toLowerCase(), allow: (j.allow ?? []).map((l) => l.toLowerCase()), port: typeof j.port === "number" ? j.port : DEFAULT_PORT }
}

export const writeConfig = (dataDir: string, c: ServerConfig): void => {
  mkdirSync(dirname(configPath(dataDir)), { recursive: true })
  writeFileSync(configPath(dataDir), `${JSON.stringify({ owner: c.owner, allow: [...new Set(c.allow)], port: c.port }, null, 2)}\n`, { mode: 0o600 })
}

/**
 * The access list as the running server sees it: the file is read again when it changed, so
 * `allow` and `deny` apply to the next request without a restart.
 */
export const liveAccess = (dataDir: string, fallback: AccessConfig): (() => AccessConfig) => {
  let cached: { mtime: number; access: AccessConfig } | null = null
  return () => {
    const file = configPath(dataDir)
    const mtime = existsSync(file) ? statSync(file).mtimeMs : 0
    if (!cached || cached.mtime !== mtime) cached = { mtime, access: readConfig(dataDir) ?? fallback }
    return cached.access
  }
}
