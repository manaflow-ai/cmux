import { describe, it, expect, beforeEach, afterEach } from "vitest";
import { execSync } from "node:child_process";
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { collectRelevantDiff } from "./collectRelevantDiff.js";

const run = (command: string, cwd: string) => {
  execSync(command, { cwd, stdio: "pipe" });
};

describe("collectRelevantDiff", () => {
  let repoDir: string;

  beforeEach(() => {
    repoDir = mkdtempSync(path.join(tmpdir(), "cmux-diff-ts-"));
    run("git init", repoDir);
    run("git config user.email test@example.com", repoDir);
    run("git config user.name Test User", repoDir);
  });

  afterEach(() => {
    rmSync(repoDir, { recursive: true, force: true });
  });

  it("collects relevant working tree changes while filtering ignored paths", async () => {
    const srcDir = path.join(repoDir, "src");
    mkdirSync(srcDir, { recursive: true });
    const appPath = path.join(srcDir, "app.ts");
    writeFileSync(appPath, "console.log('hello');\n");
    run("git add src/app.ts", repoDir);
    run("git commit -m initial", repoDir);

    writeFileSync(appPath, "console.log('hello world');\n");
    writeFileSync(path.join(srcDir, "util.ts"), "export const x = 1;\n");

    writeFileSync(path.join(repoDir, "pnpm-lock.yaml"), "lock\n");
    mkdirSync(path.join(repoDir, "node_modules/pkg"), { recursive: true });
    writeFileSync(path.join(repoDir, "node_modules/pkg/index.js"), "module.exports = 1;\n");
    mkdirSync(path.join(repoDir, "dist"));
    writeFileSync(path.join(repoDir, "dist/bundle.js"), "// built\n");
    writeFileSync(path.join(repoDir, "image.png"), Buffer.alloc(10));

    const diff = await collectRelevantDiff({ repoPath: repoDir });

    expect(diff).toContain("src/app.ts");
    expect(diff).toContain("src/util.ts");
    expect(diff).not.toContain("pnpm-lock.yaml");
    expect(diff).not.toContain("node_modules");
    expect(diff).not.toContain("dist/bundle.js");
    expect(diff).not.toContain("image.png");
  });

  it("diffs against the provided base ref when repository is clean", async () => {
    mkdirSync(path.join(repoDir, "src"), { recursive: true });
    writeFileSync(path.join(repoDir, "src/app.ts"), "console.log('initial');\n");
    run("git add src/app.ts", repoDir);
    run("git commit -m base", repoDir);
    run("git branch -M main", repoDir);

    run("git checkout -b feature", repoDir);
    writeFileSync(path.join(repoDir, "src/app.ts"), "console.log('feature');\n");
    run("git commit -am update", repoDir);

    const diff = await collectRelevantDiff({
      repoPath: repoDir,
      baseRef: "main",
    });

    expect(diff).toContain("src/app.ts");
    expect(diff).toContain("feature");
  });
});
