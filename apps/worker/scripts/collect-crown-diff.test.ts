import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execFileSync, execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function run(cmd: string, cwd: string): string {
  return execSync(cmd, { cwd, stdio: ["ignore", "pipe", "pipe"] }).toString();
}

describe("collect-crown-diff.sh", () => {
  let dir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "cmux-crown-diff-test-"));
    run("git init", dir);
    run("git config user.email test@example.com", dir);
    run("git config user.name Test User", dir);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
  });

  it("filters ignored paths and includes source changes", () => {
    const srcDir = join(dir, "src");
    mkdirSync(srcDir, { recursive: true });
    writeFileSync(join(srcDir, "index.ts"), "export const hello = 'hi';\n");
    run("git add -A && git commit -m initial", dir);

    writeFileSync(join(srcDir, "index.ts"), "export const hello = 'hello';\n");
    writeFileSync(join(srcDir, "util.ts"), "export const util = true;\n");

    writeFileSync(join(dir, "pnpm-lock.yaml"), "lock\n");
    writeFileSync(join(dir, "yarn.lock"), "lock\n");
    writeFileSync(join(dir, "package-lock.json"), "{}\n");
    mkdirSync(join(dir, "node_modules/pkg"), { recursive: true });
    writeFileSync(join(dir, "node_modules/pkg/index.js"), "module.exports = 1;\n");

    mkdirSync(join(dir, "venv/lib"), { recursive: true });
    writeFileSync(join(dir, "Pipfile.lock"), "{}\n");

    mkdirSync(join(dir, "target"), { recursive: true });
    writeFileSync(join(dir, "target/output"), "binary\n");

    const scriptPath = join(process.cwd(), "scripts/collect-crown-diff.sh");
    const diff = execFileSync("bash", [scriptPath], { cwd: dir }).toString();

    expect(diff).toContain("src/index.ts");
    expect(diff).toContain("src/util.ts");
    expect(diff).not.toContain("pnpm-lock.yaml");
    expect(diff).not.toContain("yarn.lock");
    expect(diff).not.toContain("package-lock.json");
    expect(diff).not.toContain("node_modules");
    expect(diff).not.toContain("Pipfile.lock");
    expect(diff).not.toContain("target/");
  });
});
