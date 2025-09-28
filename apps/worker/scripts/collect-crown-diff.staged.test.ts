import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execFileSync, execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function run(cmd: string, cwd: string): string {
  return execSync(cmd, { cwd, stdio: ["ignore", "pipe", "pipe"] }).toString();
}

describe("collect-crown-diff.sh with staged changes", () => {
  let dir: string;
  let originDir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "cmux-crown-staged-"));
    originDir = mkdtempSync(join(tmpdir(), "cmux-crown-origin-staged-"));

    run("git init --bare", originDir);

    run("git init", dir);
    run("git config user.email test@example.com", dir);
    run("git config user.name Test User", dir);
    run(`git remote add origin ${originDir}`, dir);

    writeFileSync(join(dir, "README.md"), "hello\n");
    run("git add -A && git commit -m base && git branch -M main", dir);
    run("git push -u origin main", dir);

    run("git symbolic-ref HEAD refs/heads/main", originDir);
    run("git fetch origin", dir);
    run("git remote set-head origin main", dir);

    run("git checkout -b feature", dir);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    rmSync(originDir, { recursive: true, force: true });
  });

  it("includes staged edits against origin base", () => {
    writeFileSync(join(dir, "README.md"), "hello staged\n");
    run("git add README.md", dir);

    const scriptPath = join(process.cwd(), "scripts/collect-crown-diff.sh");
    const diff = execFileSync("bash", [scriptPath], { cwd: dir }).toString();

    expect(diff).toContain("README.md");
    expect(diff).toContain("hello staged");
  });
});
