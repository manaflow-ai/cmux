import { execFileSync, execSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";

function run(cmd: string, cwd: string): string {
  return execSync(cmd, { cwd, stdio: ["ignore", "pipe", "pipe"] }).toString();
}

describe("collect-crown-diff.sh against remote refs", () => {
  let dir: string;
  let originDir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "cmux-crown-origin-test-"));
    originDir = mkdtempSync(join(tmpdir(), "cmux-crown-origin-bare-"));

    run("git init --bare", originDir);

    run("git init", dir);
    run("git config user.email test@example.com", dir);
    run("git config user.name Test User", dir);
    run(`git remote add origin ${originDir}`, dir);

    const src = join(dir, "src");
    mkdirSync(src, { recursive: true });
    writeFileSync(join(src, "app.ts"), "export const value = 'base';\n");
    run("git add -A && git commit -m base && git branch -M main", dir);
    run("git push -u origin main", dir);

    run("git symbolic-ref HEAD refs/heads/main", originDir);
    run("git fetch origin", dir);
    run("git remote set-head origin main", dir);

    run("git checkout -b feature", dir);
    writeFileSync(join(src, "app.ts"), "export const value = 'feature';\n");
    writeFileSync(join(src, "extra.ts"), "export const extra = true;\n");
    run("git add -A && git commit -m feature", dir);
    run("git push -u origin feature", dir);

    run("git checkout main", dir);
    run("git branch -D feature", dir);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    rmSync(originDir, { recursive: true, force: true });
  });

  it("diffs origin/feature against origin default", () => {
    const scriptPath = join(process.cwd(), "scripts/collect-crown-diff.sh");
    const diff = execFileSync(
      "bash",
      ["-lc", `CMUX_DIFF_HEAD_REF=origin/feature bash ${scriptPath}`],
      { cwd: dir }
    ).toString();

    expect(diff).toContain("src/app.ts");
    expect(diff).toContain("src/extra.ts");
    expect(diff).toContain("feature");
  });

  it("respects large file filter for remote branches", () => {
    run("git checkout -b feature-local origin/feature", dir);
    const docsDir = join(dir, "docs");
    mkdirSync(docsDir, { recursive: true });
    writeFileSync(join(docsDir, "huge.txt"), Buffer.alloc(210_000, 120));
    run("git add docs/huge.txt && git commit -m add-docs", dir);
    run("git push origin HEAD:refs/heads/feature", dir);
    run("git checkout main", dir);
    run("git branch -D feature-local", dir);

    const scriptPath = join(process.cwd(), "scripts/collect-crown-diff.sh");
    const diff = execFileSync(
      "bash",
      ["-lc", `CMUX_DIFF_HEAD_REF=origin/feature bash ${scriptPath}`],
      { cwd: dir }
    ).toString();

    expect(diff).not.toContain("docs/huge.txt");
    expect(diff).toContain("src/app.ts");
  });
});
