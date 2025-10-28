import { parse as parseDotenv } from "dotenv";
import * as fs from "node:fs";
import * as path from "node:path";
import { serverLogger } from "./fileLogger";

/**
 * EnvResolver provides hierarchical resolution of environment variables
 * from nested .env files throughout a workspace directory tree.
 *
 * Resolution strategy:
 * - Searches for .env files from the target directory up to the workspace root
 * - Variables in child directories override those in parent directories
 * - Supports multiple .env file variants (.env, .env.local, .env.development, etc.)
 * - Caches parsed results for performance
 *
 * Example hierarchy:
 *   /root/workspace/.env              <- BASE_URL=prod.example.com
 *   /root/workspace/apps/.env         <- BASE_URL=apps.example.com
 *   /root/workspace/apps/www/.env     <- BASE_URL=www.example.com
 *
 * When resolving for /root/workspace/apps/www:
 *   BASE_URL will be "www.example.com" (closest .env file wins)
 */
export class EnvResolver {
  private workspaceRoot: string;
  private cache: Map<string, Record<string, string>>;
  private fileCache: Map<string, { content: string; mtime: number }>;
  private globalEnvVars: Record<string, string>;

  /**
   * The order of .env files to search for (in priority order).
   * Files later in the list have higher priority and override earlier ones.
   */
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
   * Returns merged variables from all .env files in the hierarchy,
   * with the global environment variables as the base layer.
   *
   * @param targetPath - The directory path to resolve env vars for
   * @returns Merged environment variables object
   */
  public resolve(targetPath: string): Record<string, string> {
    const resolvedPath = path.resolve(targetPath);

    // Check if we've cached this path
    const cached = this.cache.get(resolvedPath);
    if (cached) {
      return cached;
    }

    // Start with global env vars as the base layer
    const merged: Record<string, string> = { ...this.globalEnvVars };

    // Get all directories from workspace root to target path
    const directories = this.getDirectoryHierarchy(resolvedPath);

    // For each directory in the hierarchy (from root to target)
    for (const dir of directories) {
      // For each env file name (in priority order)
      for (const fileName of this.envFileNames) {
        const envFilePath = path.join(dir, fileName);
        const parsed = this.parseEnvFile(envFilePath);

        if (parsed) {
          // Merge parsed vars, with later files overriding earlier ones
          Object.assign(merged, parsed);
          serverLogger.info(
            `[EnvResolver] Loaded ${Object.keys(parsed).length} variables from ${envFilePath}`
          );
        }
      }
    }

    // Cache the result
    this.cache.set(resolvedPath, merged);

    serverLogger.info(
      `[EnvResolver] Resolved ${Object.keys(merged).length} total variables for ${resolvedPath}`
    );

    return merged;
  }

  /**
   * Gets the hierarchy of directories from workspace root to target path.
   * Returns paths in order from root to target (parent to child).
   *
   * Example: getDirectoryHierarchy('/root/workspace/apps/www')
   * Returns: ['/root/workspace', '/root/workspace/apps', '/root/workspace/apps/www']
   */
  private getDirectoryHierarchy(targetPath: string): string[] {
    const hierarchy: string[] = [];
    let currentPath = path.resolve(targetPath);

    // Walk up the directory tree until we reach workspace root
    while (currentPath.startsWith(this.workspaceRoot)) {
      hierarchy.unshift(currentPath);

      // Stop if we've reached the workspace root
      if (currentPath === this.workspaceRoot) {
        break;
      }

      // Move up one directory
      const parentPath = path.dirname(currentPath);

      // Prevent infinite loop if dirname returns the same path
      if (parentPath === currentPath) {
        break;
      }

      currentPath = parentPath;
    }

    return hierarchy;
  }

  /**
   * Parses a single .env file and returns the key-value pairs.
   * Returns null if the file doesn't exist or can't be read.
   * Uses file modification time for cache invalidation.
   */
  private parseEnvFile(filePath: string): Record<string, string> | null {
    try {
      // Check if file exists
      const stats = fs.statSync(filePath);
      if (!stats.isFile()) {
        return null;
      }

      const mtime = stats.mtimeMs;

      // Check file cache
      const cached = this.fileCache.get(filePath);
      if (cached && cached.mtime === mtime) {
        // File hasn't changed, parse from cached content
        return parseDotenv(cached.content);
      }

      // Read and cache file content
      const content = fs.readFileSync(filePath, "utf-8");
      this.fileCache.set(filePath, { content, mtime });

      // Parse the .env file
      const parsed = parseDotenv(content);

      return parsed;
    } catch (error) {
      // File doesn't exist or can't be read
      if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
        serverLogger.warn(
          `[EnvResolver] Failed to read ${filePath}:`,
          error instanceof Error ? error.message : String(error)
        );
      }
      return null;
    }
  }

  /**
   * Clears all caches. Useful when you know .env files have changed.
   */
  public clearCache(): void {
    this.cache.clear();
    this.fileCache.clear();
    serverLogger.info("[EnvResolver] Cache cleared");
  }

  /**
   * Invalidates cache for a specific path and all its descendants.
   * Useful when a specific .env file has been modified.
   */
  public invalidatePath(targetPath: string): void {
    const resolvedPath = path.resolve(targetPath);

    // Remove entries that start with this path
    const cachedPaths = Array.from(this.cache.keys());
    for (const cachedPath of cachedPaths) {
      if (cachedPath.startsWith(resolvedPath)) {
        this.cache.delete(cachedPath);
        serverLogger.info(`[EnvResolver] Invalidated cache for ${cachedPath}`);
      }
    }

    // Also invalidate file cache for any .env files in this directory
    for (const fileName of this.envFileNames) {
      const envFilePath = path.join(resolvedPath, fileName);
      this.fileCache.delete(envFilePath);
    }
  }

  /**
   * Discovers all .env files in the workspace.
   * Returns an array of { path, vars } objects.
   */
  public discoverAllEnvFiles(): Array<{ path: string; vars: Record<string, string> }> {
    const envFiles: Array<{ path: string; vars: Record<string, string> }> = [];

    const walkDirectory = (dir: string): void => {
      try {
        const entries = fs.readdirSync(dir, { withFileTypes: true });

        for (const entry of entries) {
          const fullPath = path.join(dir, entry.name);

          if (entry.isDirectory()) {
            // Skip node_modules and hidden directories
            if (!entry.name.startsWith(".") && entry.name !== "node_modules") {
              walkDirectory(fullPath);
            }
          } else if (this.envFileNames.includes(entry.name)) {
            // Found an .env file
            const parsed = this.parseEnvFile(fullPath);
            if (parsed && Object.keys(parsed).length > 0) {
              envFiles.push({ path: fullPath, vars: parsed });
            }
          }
        }
      } catch (error) {
        serverLogger.warn(
          `[EnvResolver] Failed to read directory ${dir}:`,
          error instanceof Error ? error.message : String(error)
        );
      }
    };

    walkDirectory(this.workspaceRoot);

    serverLogger.info(
      `[EnvResolver] Discovered ${envFiles.length} .env files in workspace`
    );

    return envFiles;
  }

  /**
   * Gets a summary of all environment variables and their sources.
   * Useful for debugging and understanding where each variable comes from.
   */
  public getVariableSourceMap(
    targetPath: string
  ): Record<string, { value: string; source: string }> {
    const resolvedPath = path.resolve(targetPath);
    const sourceMap: Record<string, { value: string; source: string }> = {};

    // Add global vars first
    for (const [key, value] of Object.entries(this.globalEnvVars)) {
      sourceMap[key] = { value, source: "global" };
    }

    // Get all directories from workspace root to target path
    const directories = this.getDirectoryHierarchy(resolvedPath);

    // For each directory in the hierarchy (from root to target)
    for (const dir of directories) {
      // For each env file name (in priority order)
      for (const fileName of this.envFileNames) {
        const envFilePath = path.join(dir, fileName);
        const parsed = this.parseEnvFile(envFilePath);

        if (parsed) {
          // Record where each variable comes from
          for (const [key, value] of Object.entries(parsed)) {
            sourceMap[key] = { value, source: envFilePath };
          }
        }
      }
    }

    return sourceMap;
  }
}
