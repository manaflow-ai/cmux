import { describe, expect, it } from "vitest";
import { isValidGitConfigKey } from "./DockerVSCodeInstance";

describe("isValidGitConfigKey", () => {
  describe("valid git config keys", () => {
    it("accepts standard git config keys", () => {
      expect(isValidGitConfigKey("user.name")).toBe(true);
      expect(isValidGitConfigKey("user.email")).toBe(true);
      expect(isValidGitConfigKey("core.autocrlf")).toBe(true);
      expect(isValidGitConfigKey("http.sslVerify")).toBe(true);
    });

    it("accepts keys with dots, dashes, and underscores", () => {
      expect(isValidGitConfigKey("remote.origin.url")).toBe(true);
      expect(isValidGitConfigKey("branch.my-feature.merge")).toBe(true);
      expect(isValidGitConfigKey("core.file_mode")).toBe(true);
      expect(isValidGitConfigKey("http.proxy")).toBe(true);
    });

    it("accepts keys with numbers", () => {
      expect(isValidGitConfigKey("remote.origin2.url")).toBe(true);
      expect(isValidGitConfigKey("branch.v1.0.0.merge")).toBe(true);
    });
  });

  describe("rejects injection attempts", () => {
    it("rejects keys starting with dash (option injection)", () => {
      // Attacker tries to inject --global option
      expect(isValidGitConfigKey("--global")).toBe(false);
      expect(isValidGitConfigKey("-v")).toBe(false);
      expect(isValidGitConfigKey("--help")).toBe(false);
      expect(isValidGitConfigKey("-c")).toBe(false);
    });

    it("rejects keys with shell metacharacters", () => {
      // Semicolon (command separator)
      expect(isValidGitConfigKey("user.name; rm -rf /")).toBe(false);
      expect(isValidGitConfigKey("; whoami")).toBe(false);

      // Pipe
      expect(isValidGitConfigKey("user.name | cat /etc/passwd")).toBe(false);

      // Ampersand
      expect(isValidGitConfigKey("user.name && rm -rf /")).toBe(false);
      expect(isValidGitConfigKey("user.name & echo test")).toBe(false);

      // Backtick (command substitution)
      expect(isValidGitConfigKey("user.name`whoami`")).toBe(false);
      expect(isValidGitConfigKey("`id`")).toBe(false);

      // Dollar sign (variable expansion)
      expect(isValidGitConfigKey("user.$HOME")).toBe(false);
      expect(isValidGitConfigKey("$(whoami)")).toBe(false);

      // Quotes
      expect(isValidGitConfigKey("user.name'")).toBe(false);
      expect(isValidGitConfigKey('user.name"')).toBe(false);

      // Newlines
      expect(isValidGitConfigKey("user.name\nwhoami")).toBe(false);

      // Spaces
      expect(isValidGitConfigKey("user name")).toBe(false);

      // Slashes
      expect(isValidGitConfigKey("/etc/passwd")).toBe(false);
      expect(isValidGitConfigKey("user\\name")).toBe(false);
    });

    it("rejects keys with parentheses", () => {
      expect(isValidGitConfigKey("user.name()")).toBe(false);
      expect(isValidGitConfigKey("$(cat)")).toBe(false);
    });

    it("rejects empty strings", () => {
      expect(isValidGitConfigKey("")).toBe(false);
    });

    it("rejects keys with special URL characters", () => {
      expect(isValidGitConfigKey("user@name")).toBe(false);
      expect(isValidGitConfigKey("user:name")).toBe(false);
      expect(isValidGitConfigKey("user?name")).toBe(false);
      expect(isValidGitConfigKey("user#name")).toBe(false);
    });
  });

  describe("edge cases", () => {
    it("accepts single character keys", () => {
      expect(isValidGitConfigKey("a")).toBe(true);
      expect(isValidGitConfigKey("1")).toBe(true);
    });

    it("allows dashes in the middle of keys", () => {
      expect(isValidGitConfigKey("my-key")).toBe(true);
      expect(isValidGitConfigKey("user.my-name")).toBe(true);
      expect(isValidGitConfigKey("branch.feature-branch.merge")).toBe(true);
    });

    it("rejects only a dash", () => {
      expect(isValidGitConfigKey("-")).toBe(false);
    });
  });
});
