import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execFileSync, execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

function run(cmd: string, cwd: string): string {
  return execSync(cmd, { cwd, stdio: ["ignore", "pipe", "pipe"] }).toString();
}

describe("collect-crown-diff.sh with origin default branch 'dev'", () => {
  let dir: string;
  let originDir: string;

  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "cmux-crown-dev-default-"));
    originDir = mkdtempSync(join(tmpdir(), "cmux-crown-origin-dev-"));

    run("git init --bare", originDir);

    run("git init", dir);
    run("git config user.email test@example.com", dir);
    run("git config user.name Test User", dir);
    run(`git remote add origin ${originDir}`, dir);

    const src = join(dir, "src");
    mkdirSync(src, { recursive: true });
    writeFileSync(join(src, "app.ts"), "console.log('dev');\n");
    run("git add -A && git commit -m base && git branch -M dev", dir);
    run("git push -u origin dev", dir);

    run("git symbolic-ref HEAD refs/heads/dev", originDir);
    run("git fetch origin", dir);
    run("git remote set-head origin dev", dir);

    run("git checkout -b feature", dir);
    writeFileSync(join(src, "app.ts"), "console.log('feature');\n");
    writeFileSync(join(src, "util.ts"), "export const util = true;\n");
    run("git add -A && git commit -m feature", dir);
    run("git push -u origin feature", dir);
    run("git checkout dev", dir);
    run("git branch -D feature", dir);
  });

  afterEach(() => {
    rmSync(dir, { recursive: true, force: true });
    rmSync(originDir, { recursive: true, force: true });
  });

  it("diffs origin/feature against origin/dev", () => {
    const scriptPath = join(process.cwd(), "scripts/collect-crown-diff.sh");
    const diff = execFileSync(
      "bash",
      ["-lc", `CMUX_DIFF_HEAD_REF=origin/feature bash ${scriptPath}`],
      { cwd: dir }
    ).toString();

    expect(diff).toContain("src/app.ts");
    expect(diff).toContain("src/util.ts");
  });
});
