import { parse as parseDotenv } from "dotenv";
import * as fs from "node:fs";
import * as path from "node:path";
import { log } from "./logger";

/**
 * Worker-side EnvResolver for hierarchical environment variable resolution.
 * This is a simplified version optimized for the worker container environment.
 */
export class EnvResolver {
  private workspaceRoot: string;
  private cache: Map<string, Record<string, string>>;
  private fileCache: Map<string, { content: string; mtime: number }>;
  private globalEnvVars: Record<string, string>;

  private readonly envFileNames = [
    ".env",
    ".env.local",
    ".env.development",
    ".env.development.local",
  ];

  constructor(workspaceRoot: string, globalEnvVars: Record<string, string> = {}) {
    this.workspaceRoot = path.resolve(workspaceRoot);
    this.cache = new Map();
    this.fileCache = new Map();
    this.globalEnvVars = globalEnvVars;
  }

  /**
   * Resolves environment variables for a specific directory path.
   */
  public resolve(targetPath: string): Record<string, string> {
    const resolvedPath = path.resolve(targetPath);

    const cached = this.cache.get(resolvedPath);
    if (cached) {
      return cached;
    }

    const merged: Record<string, string> = { ...this.globalEnvVars };
    const directories = this.getDirectoryHierarchy(resolvedPath);

    for (const dir of directories) {
      for (const fileName of this.envFileNames) {
        const envFilePath = path.join(dir, fileName);
        const parsed = this.parseEnvFile(envFilePath);

        if (parsed) {
          Object.assign(merged, parsed);
          log("INFO", `[EnvResolver] Loaded ${Object.keys(parsed).length} variables from ${envFilePath}`);
        }
      }
    }

    this.cache.set(resolvedPath, merged);

    log("INFO", `[EnvResolver] Resolved ${Object.keys(merged).length} total variables for ${resolvedPath}`);

    return merged;
  }

  private getDirectoryHierarchy(targetPath: string): string[] {
    const hierarchy: string[] = [];
    let currentPath = path.resolve(targetPath);

    while (currentPath.startsWith(this.workspaceRoot)) {
      hierarchy.unshift(currentPath);

      if (currentPath === this.workspaceRoot) {
        break;
      }

      const parentPath = path.dirname(currentPath);

      if (parentPath === currentPath) {
        break;
      }

      currentPath = parentPath;
    }

    return hierarchy;
  }

  private parseEnvFile(filePath: string): Record<string, string> | null {
    try {
      const stats = fs.statSync(filePath);
      if (!stats.isFile()) {
        return null;
      }

      const mtime = stats.mtimeMs;

      const cached = this.fileCache.get(filePath);
      if (cached && cached.mtime === mtime) {
        return parseDotenv(cached.content);
      }

      const content = fs.readFileSync(filePath, "utf-8");
      this.fileCache.set(filePath, { content, mtime });

      const parsed = parseDotenv(content);

      return parsed;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        log("WARN", `[EnvResolver] Failed to read ${filePath}: ${error}`);
      }
      return null;
    }
  }

  public clearCache(): void {
    this.cache.clear();
    this.fileCache.clear();
    log("INFO", "[EnvResolver] Cache cleared");
  }

  public invalidatePath(targetPath: string): void {
    const resolvedPath = path.resolve(targetPath);

    const cachedPaths = Array.from(this.cache.keys());
    for (const cachedPath of cachedPaths) {
      if (cachedPath.startsWith(resolvedPath)) {
        this.cache.delete(cachedPath);
        log("INFO", `[EnvResolver] Invalidated cache for ${cachedPath}`);
      }
    }

    for (const fileName of this.envFileNames) {
      const envFilePath = path.join(resolvedPath, fileName);
      this.fileCache.delete(envFilePath);
    }
  }
}

// Singleton instance for the worker
let globalResolver: EnvResolver | null = null;

/**
 * Initializes the global EnvResolver instance with the workspace root and global vars.
 * Should be called once when the worker starts or when a terminal is created.
 */
export function initializeEnvResolver(
  workspaceRoot: string,
  globalEnvVars: Record<string, string> = {}
): void {
  globalResolver = new EnvResolver(workspaceRoot, globalEnvVars);
  log("INFO", `[EnvResolver] Initialized with workspace root: ${workspaceRoot}`);
}

/**
 * Resolves environment variables for a given directory path using the global resolver.
 * Returns the global env vars if the resolver hasn't been initialized yet.
 */
export function resolveEnvForPath(
  targetPath: string,
  fallbackEnv: Record<string, string> = {}
): Record<string, string> {
  if (!globalResolver) {
    log("WARN", "[EnvResolver] Resolver not initialized, using fallback env");
    return fallbackEnv;
  }

  return globalResolver.resolve(targetPath);
}

/**
 * Clears the env resolver cache. Useful after file system changes.
 */
export function clearEnvCache(): void {
  if (globalResolver) {
    globalResolver.clearCache();
  }
}

/**
 * Gets the current global resolver instance (for testing or advanced usage).
 */
export function getEnvResolver(): EnvResolver | null {
  return globalResolver;
}
