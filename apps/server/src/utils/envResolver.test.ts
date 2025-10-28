import { afterEach, beforeEach, describe, expect, it } from "vitest";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { EnvResolver } from "./envResolver";

describe("EnvResolver", () => {
  let tempDir: string;
  let resolver: EnvResolver;

  beforeEach(() => {
    // Create a temporary directory for test files
    tempDir = fs.mkdtempSync(path.join(os.tmpdir(), "envresolver-test-"));
    resolver = new EnvResolver(tempDir);
  });

  afterEach(() => {
    // Clean up temporary directory
    fs.rmSync(tempDir, { recursive: true, force: true });
  });

  it("should resolve environment variables from a single .env file", () => {
    // Create .env file in root
    const envContent = "API_KEY=secret123\nDATABASE_URL=postgres://localhost";
    fs.writeFileSync(path.join(tempDir, ".env"), envContent);

    const result = resolver.resolve(tempDir);

    expect(result).toEqual({
      API_KEY: "secret123",
      DATABASE_URL: "postgres://localhost",
    });
  });

  it("should merge variables from parent and child directories", () => {
    // Create root .env
    fs.writeFileSync(path.join(tempDir, ".env"), "API_KEY=root\nROOT_VAR=rootvalue");

    // Create apps directory with .env
    const appsDir = path.join(tempDir, "apps");
    fs.mkdirSync(appsDir);
    fs.writeFileSync(path.join(appsDir, ".env"), "API_KEY=apps\nAPPS_VAR=appsvalue");

    // Resolve for apps directory
    const result = resolver.resolve(appsDir);

    expect(result).toEqual({
      API_KEY: "apps", // Child overrides parent
      ROOT_VAR: "rootvalue", // Inherited from parent
      APPS_VAR: "appsvalue", // From child
    });
  });

  it("should respect priority order of .env file variants", () => {
    // Create multiple .env variants in the same directory
    fs.writeFileSync(path.join(tempDir, ".env"), "VAR=base");
    fs.writeFileSync(path.join(tempDir, ".env.local"), "VAR=local");
    fs.writeFileSync(path.join(tempDir, ".env.development"), "VAR=dev");

    const result = resolver.resolve(tempDir);

    // .env.development should win (highest priority in the list)
    expect(result.VAR).toBe("dev");
  });

  it("should handle deeply nested directory structures", () => {
    // Create multi-level hierarchy
    fs.writeFileSync(path.join(tempDir, ".env"), "LEVEL=root");

    const level1 = path.join(tempDir, "level1");
    fs.mkdirSync(level1);
    fs.writeFileSync(path.join(level1, ".env"), "LEVEL=1");

    const level2 = path.join(level1, "level2");
    fs.mkdirSync(level2);
    fs.writeFileSync(path.join(level2, ".env"), "LEVEL=2");

    const level3 = path.join(level2, "level3");
    fs.mkdirSync(level3);
    fs.writeFileSync(path.join(level3, ".env"), "LEVEL=3");

    const result = resolver.resolve(level3);

    expect(result.LEVEL).toBe("3");
  });

  it("should cache resolved results", () => {
    fs.writeFileSync(path.join(tempDir, ".env"), "VAR=original");

    // First resolution
    const result1 = resolver.resolve(tempDir);
    expect(result1.VAR).toBe("original");

    // Modify file (should still return cached result)
    fs.writeFileSync(path.join(tempDir, ".env"), "VAR=modified");
    const result2 = resolver.resolve(tempDir);
    expect(result2.VAR).toBe("original"); // Still cached

    // Clear cache and resolve again
    resolver.clearCache();
    const result3 = resolver.resolve(tempDir);
    expect(result3.VAR).toBe("modified");
  });

  it("should invalidate cache for specific paths", () => {
    fs.writeFileSync(path.join(tempDir, ".env"), "ROOT=root");

    const subDir = path.join(tempDir, "sub");
    fs.mkdirSync(subDir);
    fs.writeFileSync(path.join(subDir, ".env"), "SUB=sub");

    // Resolve both paths
    resolver.resolve(tempDir);
    resolver.resolve(subDir);

    // Modify subdir .env
    fs.writeFileSync(path.join(subDir, ".env"), "SUB=modified");

    // Invalidate only subdir
    resolver.invalidatePath(subDir);

    // Root should still be cached, subdir should be fresh
    const rootResult = resolver.resolve(tempDir);
    const subResult = resolver.resolve(subDir);

    expect(rootResult.ROOT).toBe("root");
    expect(subResult.SUB).toBe("modified");
  });

  it("should handle global environment variables as base layer", () => {
    const globalVars = { GLOBAL_VAR: "global", OVERRIDE_ME: "global" };
    const resolverWithGlobal = new EnvResolver(tempDir, globalVars);

    fs.writeFileSync(path.join(tempDir, ".env"), "OVERRIDE_ME=local\nLOCAL_VAR=local");

    const result = resolverWithGlobal.resolve(tempDir);

    expect(result).toEqual({
      GLOBAL_VAR: "global", // From global
      OVERRIDE_ME: "local", // Local overrides global
      LOCAL_VAR: "local", // From local
    });
  });

  it("should discover all .env files in workspace", () => {
    // Create .env files in multiple locations
    fs.writeFileSync(path.join(tempDir, ".env"), "ROOT=1");

    const apps = path.join(tempDir, "apps");
    fs.mkdirSync(apps);
    fs.writeFileSync(path.join(apps, ".env"), "APPS=1");

    const www = path.join(apps, "www");
    fs.mkdirSync(www);
    fs.writeFileSync(path.join(www, ".env.local"), "WWW=1");

    const discovered = resolver.discoverAllEnvFiles();

    expect(discovered).toHaveLength(3);
    expect(discovered.map((f) => f.path)).toContain(path.join(tempDir, ".env"));
    expect(discovered.map((f) => f.path)).toContain(path.join(apps, ".env"));
    expect(discovered.map((f) => f.path)).toContain(path.join(www, ".env.local"));
  });

  it("should skip node_modules and hidden directories", () => {
    fs.writeFileSync(path.join(tempDir, ".env"), "ROOT=1");

    // Create node_modules with .env (should be skipped)
    const nodeModules = path.join(tempDir, "node_modules");
    fs.mkdirSync(nodeModules);
    fs.writeFileSync(path.join(nodeModules, ".env"), "NODE_MODULES=1");

    // Create hidden dir with .env (should be skipped)
    const hiddenDir = path.join(tempDir, ".hidden");
    fs.mkdirSync(hiddenDir);
    fs.writeFileSync(path.join(hiddenDir, ".env"), "HIDDEN=1");

    const discovered = resolver.discoverAllEnvFiles();

    // Should only find root .env
    expect(discovered).toHaveLength(1);
    expect(discovered[0].path).toBe(path.join(tempDir, ".env"));
  });

  it("should provide variable source map", () => {
    const globalVars = { GLOBAL_VAR: "global" };
    const resolverWithGlobal = new EnvResolver(tempDir, globalVars);

    fs.writeFileSync(path.join(tempDir, ".env"), "ROOT_VAR=root");

    const subDir = path.join(tempDir, "sub");
    fs.mkdirSync(subDir);
    fs.writeFileSync(path.join(subDir, ".env"), "SUB_VAR=sub\nROOT_VAR=overridden");

    const sourceMap = resolverWithGlobal.getVariableSourceMap(subDir);

    expect(sourceMap.GLOBAL_VAR).toEqual({
      value: "global",
      source: "global",
    });

    expect(sourceMap.ROOT_VAR).toEqual({
      value: "overridden",
      source: path.join(subDir, ".env"),
    });

    expect(sourceMap.SUB_VAR).toEqual({
      value: "sub",
      source: path.join(subDir, ".env"),
    });
  });

  it("should handle missing .env files gracefully", () => {
    // No .env files exist
    const result = resolver.resolve(tempDir);

    expect(result).toEqual({});
  });

  it("should handle malformed .env files gracefully", () => {
    // Create .env with invalid content
    fs.writeFileSync(path.join(tempDir, ".env"), "VALID=yes\nINVALID LINE WITHOUT EQUALS\nALSO_VALID=yes");

    const result = resolver.resolve(tempDir);

    // dotenv library should parse valid lines and skip invalid ones
    expect(result.VALID).toBe("yes");
    expect(result.ALSO_VALID).toBe("yes");
  });

  it("should handle variables with special characters", () => {
    const envContent = `
DATABASE_URL="postgres://user:pass@localhost:5432/db"
JSON_CONFIG='{"key": "value"}'
MULTILINE="line1
line2
line3"
EMPTY=
SPACES="  spaces  "
`;
    fs.writeFileSync(path.join(tempDir, ".env"), envContent);

    const result = resolver.resolve(tempDir);

    expect(result.DATABASE_URL).toBe("postgres://user:pass@localhost:5432/db");
    expect(result.JSON_CONFIG).toBe('{"key": "value"}');
    expect(result.EMPTY).toBe("");
    expect(result.SPACES).toBe("  spaces  ");
  });
});
