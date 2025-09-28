import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execFileSync, execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function run(cmd: string, cwd: string): string {
  return execSync(cmd, { cwd, stdio: ["ignore", "pipe", "pipe"] }).toString();
}

describe("collect-crown-diff.sh with CMUX_DIFF_BASE override", () => {
  let dir: string;
  let originDir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "cmux-crown-base-override-"));
    originDir = mkdtempSync(join(tmpdir(), "cmux-crown-origin-override-"));

    run("git init --bare", originDir);

    run("git init", dir);
    run("git config user.email test@example.com", dir);
    run("git config user.name Test User", dir);
    run(`git remote add origin ${originDir}`, dir);

    writeFileSync(join(dir, "README.md"), "base\n");
    run("git add -A && git commit -m base && git branch -M main", dir);
    run("git push -u origin main", dir);

    run("git symbolic-ref HEAD refs/heads/main", originDir);
    run("git fetch origin", dir);
    run("git remote set-head origin main", dir);

    run("git checkout -b feature", dir);
    writeFileSync(join(dir, "README.md"), "feature\n");
    run("git add README.md && git commit -m feature", dir);
    run("git push -u origin feature", dir);
    run("git checkout main", dir);
    run("git branch -D feature", dir);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    rmSync(originDir, { recursive: true, force: true });
  });

  it("produces empty diff when base equals head override", () => {
    const scriptPath = join(process.cwd(), "scripts/collect-crown-diff.sh");

    const diffDefault = execFileSync(
      "bash",
      ["-lc", `CMUX_DIFF_HEAD_REF=origin/feature bash ${scriptPath}`],
      { cwd: dir }
    ).toString();
    expect(diffDefault).toContain("README.md");

    const diffOverride = execFileSync(
      "bash",
      [
        "-lc",
        `CMUX_DIFF_BASE=origin/feature CMUX_DIFF_HEAD_REF=origin/feature bash ${scriptPath}`,
      ],
      { cwd: dir }
    ).toString();
    expect(diffOverride).toBe("");
  });
});
