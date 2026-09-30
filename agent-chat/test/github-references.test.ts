// The agent chat transcript shows the same bare GitHub references the terminal
// shows: `#847`, `owner/repo#847`, `GH-1234`, and abbreviated commit SHAs. The
// rules here are the TypeScript half of TerminalGitHubReferenceDetector, and
// the two have to agree, because the same sentence can be read in either
// surface and a reader should not have to know which one they are looking at.
import { describe, expect, test } from "bun:test";
import { gitHubReference } from "../src/githubReferences";

const SLUG = "manaflow-ai/cmux";

describe("gitHubReference", () => {
  test("reads a bare issue number against the session repository", () => {
    expect(gitHubReference("#847", SLUG)?.url).toBe("https://github.com/manaflow-ai/cmux/issues/847");
  });

  test("leaves a bare issue number alone when the repository is unknown", () => {
    expect(gitHubReference("#847", null)).toBeNull();
  });

  test("reads an explicit slug without needing the session repository", () => {
    expect(gitHubReference("teamleaderleo/stensibly#12", null)?.url)
      .toBe("https://github.com/teamleaderleo/stensibly/issues/12");
  });

  test("drops a .git suffix from an explicit slug", () => {
    expect(gitHubReference("owner/repo.git#12", null)?.url)
      .toBe("https://github.com/owner/repo/issues/12");
  });

  test("reads the GH-1234 form commit trailers use", () => {
    expect(gitHubReference("GH-1234", SLUG)?.url).toBe("https://github.com/manaflow-ai/cmux/issues/1234");
    expect(gitHubReference("gh-1234", SLUG)?.url).toBe("https://github.com/manaflow-ai/cmux/issues/1234");
  });

  test("trims wrapping punctuation the way prose writes it", () => {
    expect(gitHubReference("(#847)", SLUG)?.url).toBe("https://github.com/manaflow-ai/cmux/issues/847");
    expect(gitHubReference("#847,", SLUG)?.url).toBe("https://github.com/manaflow-ai/cmux/issues/847");
    expect(gitHubReference("`#847`", SLUG)?.url).toBe("https://github.com/manaflow-ai/cmux/issues/847");
  });

  test("rejects issue numbers that are not numbers GitHub hands out", () => {
    expect(gitHubReference("#0", SLUG)).toBeNull();
    expect(gitHubReference("#012", SLUG)).toBeNull();
    expect(gitHubReference("#", SLUG)).toBeNull();
    expect(gitHubReference("#12a", SLUG)).toBeNull();
    expect(gitHubReference("#1234567890", SLUG)).toBeNull();
  });

  test("leaves anything carrying a URL scheme to the markdown autolinker", () => {
    expect(gitHubReference("https://example.com/page#847", SLUG)).toBeNull();
  });

  test("reads an abbreviated commit SHA", () => {
    expect(gitHubReference("a360a95", SLUG)?.url)
      .toBe("https://github.com/manaflow-ai/cmux/commit/a360a95");
    expect(gitHubReference("2a0138193e31", SLUG)?.url)
      .toBe("https://github.com/manaflow-ai/cmux/commit/2a0138193e31");
  });

  test("does not read ordinary numbers and words as commits", () => {
    // All digits is a number, all letters is a word. Requiring both is what
    // keeps a click on `12345678` or `deadbeef` off GitHub.
    expect(gitHubReference("12345678", SLUG)).toBeNull();
    expect(gitHubReference("deadbeef", SLUG)).toBeNull();
    expect(gitHubReference("abc123", SLUG)).toBeNull();
  });

  test("does not read checksum output as a commit", () => {
    // 40 hex is what sha1sum prints and 32 is what md5sum prints. Accepting
    // those lengths turns a checksum into a link to a commit that does not exist.
    expect(gitHubReference("2a0138193e3130fd5a820ce7417d43c484b76a9f", SLUG)).toBeNull();
    expect(gitHubReference("9e107d9d372bb6826bd81d3542a419d6", SLUG)).toBeNull();
  });

  test("needs the session repository for a commit SHA", () => {
    expect(gitHubReference("a360a95", null)).toBeNull();
  });
});
