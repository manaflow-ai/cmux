import { describe, expect, it } from "vitest";
import { Buffer } from "node:buffer";

import {
  encodeEnvContentForEnvctl,
  ensureQuotedEnvVarsContent,
} from "./ensure-env-vars";

describe("ensureQuotedEnvVarsContent", () => {
  it("wraps unquoted values", () => {
    const input = "FOO=bar\nBAR=baz";
    const result = ensureQuotedEnvVarsContent(input);
    expect(result).toBe('FOO="bar"\nBAR="baz"');
  });

  it("preserves existing double quotes", () => {
    const input = 'FOO="already"\nBAR="value"';
    const result = ensureQuotedEnvVarsContent(input);
    expect(result).toBe(input);
  });

  it("converts single quotes to double quotes", () => {
    const input = "FOO='single quoted'";
    const result = ensureQuotedEnvVarsContent(input);
    expect(result).toBe('FOO="single quoted"');
  });

  it("combines multi-line values until next key", () => {
    const input = [
      "CERT=-----BEGIN CERT-----",
      "line-1",
      "line-2==",
      "-----END CERT-----",
      "NEXT=ok",
    ].join("\n");
    const result = ensureQuotedEnvVarsContent(input);
    expect(result).toBe(
      'CERT="-----BEGIN CERT-----\\nline-1\\nline-2==\\n-----END CERT-----"\nNEXT="ok"'
    );
  });

  it("handles export prefix", () => {
    const input = "export TOKEN=value";
    const result = ensureQuotedEnvVarsContent(input);
    expect(result).toBe('TOKEN="value"');
  });
});

describe("encodeEnvContentForEnvctl", () => {
  it("encodes quoted content to base64", () => {
    const encoded = encodeEnvContentForEnvctl("FOO=bar");
    const decoded = Buffer.from(encoded, "base64").toString("utf8");
    expect(decoded).toBe('FOO="bar"');
  });
});
