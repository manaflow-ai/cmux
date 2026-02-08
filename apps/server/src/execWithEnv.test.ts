import { describe, expect, it } from "vitest";
import { escapeForSingleQuotes } from "./execWithEnv";

describe("escapeForSingleQuotes", () => {
  it("returns string unchanged when no single quotes", () => {
    expect(escapeForSingleQuotes("hello world")).toBe("hello world");
    expect(escapeForSingleQuotes("echo test")).toBe("echo test");
    expect(escapeForSingleQuotes("")).toBe("");
  });

  it("escapes single quotes properly", () => {
    // A single quote becomes: end quote, escaped quote, start quote: '\''
    expect(escapeForSingleQuotes("it's")).toBe("it'\\''s");
    expect(escapeForSingleQuotes("'")).toBe("'\\''");
    expect(escapeForSingleQuotes("'hello'")).toBe("'\\''hello'\\''");
  });

  it("handles multiple single quotes", () => {
    expect(escapeForSingleQuotes("it's a 'test'")).toBe("it'\\''s a '\\''test'\\''");
    expect(escapeForSingleQuotes("'''")).toBe("'\\'''\\'''\\''");
  });

  it("prevents shell injection via single quote escape", () => {
    // Attack: trying to break out of quotes with: foo'; rm -rf /; echo '
    // Without escaping, wrapping in single quotes would allow injection:
    //   /bin/zsh -c 'foo'; rm -rf /; echo ''
    // With escaping, the single quotes become literal:
    //   /bin/zsh -c 'foo'\''; rm -rf /; echo '\'''
    const malicious = "foo'; rm -rf /; echo '";
    const escaped = escapeForSingleQuotes(malicious);

    // Each ' becomes '\''
    // So: foo' -> foo'\''
    // ; rm -rf /; echo  -> stays same (no single quotes)
    // ' -> '\''
    // Result: foo'\''; rm -rf /; echo '\''
    expect(escaped).toBe("foo'\\''; rm -rf /; echo '\\''");
  });

  it("handles command injection attempts with backticks safely", () => {
    // Backticks are safe inside single quotes - they're treated literally
    const withBackticks = "echo `whoami`";
    expect(escapeForSingleQuotes(withBackticks)).toBe("echo `whoami`");
  });

  it("handles command injection attempts with $(...) safely", () => {
    // $() is safe inside single quotes - treated literally
    const withSubshell = "echo $(whoami)";
    expect(escapeForSingleQuotes(withSubshell)).toBe("echo $(whoami)");
  });

  it("handles simple injection with single quote", () => {
    // Simple case: just one single quote
    const input = "test'end";
    const expected = "test'\\''end";
    expect(escapeForSingleQuotes(input)).toBe(expected);
  });
});
