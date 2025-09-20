import { describe, expect, test } from "vitest";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import { compareRefsForRepo } from "./compareRefs.js";

function run(cwd: string, cmd: string) {
  const shell = process.platform === "win32" ? "cmd" : "sh";
  const args = process.platform === "win32" ? ["/C", cmd] : ["-c", cmd];
  const res = spawnSync(shell, args, { cwd, stdio: "pipe", encoding: "utf8" });
  if (res.status !== 0) {
    throw new Error(`Command failed (${res.status}): ${cmd}\n${res.stdout}\n${res.stderr}`);
  }
  return res.stdout.trim();
}

function initRepo(): string {
  const dir = mkdtempSync(join(tmpdir(), "cmux-git-"));
  run(dir, "git init");
  run(dir, "git -c user.email=a@b -c user.name=test checkout -b main");
  writeFileSync(join(dir, "a.txt"), "hello\n");
  run(dir, "git add .");
  run(dir, "git -c user.email=a@b -c user.name=test commit -m base");
  return dir;
}

describe("compareRefsForRepo (native)", () => {
  test("detects pure rename via identity (unchanged content)", async () => {
    const repo = initRepo();
    run(repo, "git checkout -b feature");
    run(repo, "git mv a.txt b.txt");
    run(repo, "git -c user.email=a@b -c user.name=test commit -m rename");

    const diffs = await compareRefsForRepo({
      ref1: "main",
      ref2: "feature",
      originPathOverride: repo,
    });

    // Expect a single rename entry noting the rename without loading contents
    expect(Array.isArray(diffs)).toBe(true);
    const rename = diffs.find((d) => d.status === "renamed");
    expect(rename).toBeTruthy();
    expect(rename!.oldPath).toBe("a.txt");
    expect(rename!.filePath).toBe("b.txt");
    expect(rename!.isBinary).toBe(false);
    // unchanged content, additions/deletions 0
    expect(rename!.additions).toBe(0);
    expect(rename!.deletions).toBe(0);
    expect(rename!.contentOmitted).toBe(true);
    expect(rename!.oldContent).toBeUndefined();
    expect(rename!.newContent).toBeUndefined();
  });

  test("added and deleted without rename when content changes", async () => {
    const repo = initRepo();
    run(repo, "git checkout -b feature");
    // simulate rename+modify: rename then change content in new path
    run(repo, "git mv a.txt b.txt");
    writeFileSync(join(repo, "b.txt"), "hello world\n");
    run(repo, "git add .");
    run(repo, "git -c user.email=a@b -c user.name=test commit -m rename_modify");

    const diffs = await compareRefsForRepo({
      ref1: "main",
      ref2: "feature",
      originPathOverride: repo,
    });

    // With identity-based detection only, this shows added+deleted
    const added = diffs.find((d) => d.status === "added" && d.filePath === "b.txt");
    const deleted = diffs.find((d) => d.status === "deleted" && d.filePath === "a.txt");
    expect(added).toBeTruthy();
    expect(deleted).toBeTruthy();
  });

  test("modified in place", async () => {
    const repo = initRepo();
    run(repo, "git checkout -b feature");
    // modify the file without renaming
    writeFileSync(join(repo, "a.txt"), "hello\nworld\n");
    run(repo, "git add .");
    run(repo, "git -c user.email=a@b -c user.name=test commit -m change");

    const diffs = await compareRefsForRepo({
      ref1: "main",
      ref2: "feature",
      originPathOverride: repo,
    });

    const mod = diffs.find((d) => d.status === "modified" && d.filePath === "a.txt");
    expect(mod).toBeTruthy();
    expect(mod!.isBinary).toBe(false);
    expect(mod!.additions).toBeGreaterThanOrEqual(1);
  });
});

