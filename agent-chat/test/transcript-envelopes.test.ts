import { describe, expect, test } from "bun:test";
import { parseTranscriptText } from "../adapters/transcript";

// Claude Code writes these user lines itself; the person never typed them.
const line = (record: Record<string, unknown>) => JSON.stringify(record);

describe("Claude Code envelopes in a transcript", () => {
  test("another session's message is a message from that session, never raw XML", () => {
    const text = [
      line({ type: "user", uuid: "u1", message: { role: "user", content: "Fix the parser" } }),
      line({
        type: "user",
        uuid: "u2",
        isMeta: true,
        origin: { kind: "peer", from: "local_22fd", hostInjected: true },
        message: {
          role: "user",
          content:
            'Another Claude session sent a message:\n<cross-session-message from="local_22fd" name="Second coordinator">\n#21884 came back &lt;FIX FIRST&gt;.\n</cross-session-message>',
        },
      }),
    ].join("\n");
    const { events } = parseTranscriptText("claude", text);
    const messages = events.filter((e) => e.kind === "agent-message");
    expect(messages).toEqual([{ kind: "agent-message", id: "u2", from: "Second coordinator", body: "#21884 came back <FIX FIRST>." }]);
    expect(JSON.stringify(events)).not.toContain("cross-session-message");
  });

  test("a message with no name is from its session id", () => {
    const text = line({
      type: "user",
      uuid: "u3",
      isMeta: true,
      origin: { kind: "peer", from: "local_9a" },
      message: { role: "user", content: '<cross-session-message from="local_9a">hi</cross-session-message>' },
    });
    const { events } = parseTranscriptText("claude", text);
    expect(events.filter((e) => e.kind === "agent-message")).toEqual([{ kind: "agent-message", id: "u3", from: "local_9a", body: "hi" }]);
  });

  test("a task notification without an origin is still a status line, not a prompt", () => {
    const text = line({
      type: "user",
      uuid: "u4",
      message: { role: "user", content: "<task-notification>\n<task-id>a1</task-id>\n<status>completed</status>\n<summary>Agent finished</summary>\n</task-notification>" },
    });
    const { events } = parseTranscriptText("claude", text);
    expect(events.some((e) => e.kind === "user")).toBe(false);
    expect(JSON.stringify(events)).not.toContain("<task-notification>");
  });
});
