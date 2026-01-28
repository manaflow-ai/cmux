import { describe, expect, it } from "vitest";
import {
  assertSafeGitRef,
  assertSafeGitRemoteUrl,
  isSafeGitRef,
  isSafeGitRemoteUrl,
} from "./gitValidation";

describe("gitValidation", () => {
  it("accepts safe git refs", () => {
    expect(isSafeGitRef("main")).toBe(true);
    expect(isSafeGitRef("feature/foo")).toBe(true);
    expect(isSafeGitRef("release/v1.2.3")).toBe(true);
    expect(isSafeGitRef("hotfix_bug-123")).toBe(true);
    expect(isSafeGitRef("a1b2c3d4")).toBe(true);
    expect(isSafeGitRef("0123456789abcdef0123456789abcdef01234567")).toBe(
      true
    );
  });

  it("rejects unsafe git refs", () => {
    const unsafeRefs = [
      "",
      " feature",
      "feature ",
      "-bad",
      "../bad",
      "bad..ref",
      "bad//ref",
      "bad/./ref",
      "bad/../ref",
      "bad@{1}",
      "bad~name",
      "bad^name",
      "bad:name",
      "bad?name",
      "bad*name",
      "bad[name",
      "bad ref",
    ];

    for (const ref of unsafeRefs) {
      expect(isSafeGitRef(ref)).toBe(false);
    }
  });

  it("accepts safe GitHub remote URLs", () => {
    const urls = [
      "https://github.com/org/repo",
      "https://github.com/org/repo.git",
      "https://x-access-token:token@github.com/org/repo.git",
      "git@github.com:org/repo.git",
    ];

    for (const url of urls) {
      expect(isSafeGitRemoteUrl(url)).toBe(true);
    }
  });

  it("rejects unsafe remote URLs", () => {
    const urls = [
      "",
      " https://github.com/org/repo",
      "https://example.com/org/repo",
      "http://github.com/org/repo",
      "file:///tmp/repo",
      "-c core.sshCommand=evil",
      "https://github.com/org",
      "https://github.com/org/repo/extra",
    ];

    for (const url of urls) {
      expect(isSafeGitRemoteUrl(url)).toBe(false);
    }
  });

  it("assert helpers throw on invalid input", () => {
    expect(() => assertSafeGitRef("bad ref", "branch")).toThrow(
      /Unsafe git ref/
    );
    expect(() => assertSafeGitRemoteUrl("http://github.com/org/repo", "repo")).toThrow(
      /Unsafe git remote URL/
    );
  });
});
