import { expect, test } from "bun:test";
import { acpPromptFromMail } from "../adapters/acp";

test("renders a durable mail envelope as ACP prompt text", () => {
  expect(acpPromptFromMail({
    id: "m-42",
    threadId: "t-7",
    sender: "claude@workspace",
    recipients: ["codex@workspace", "review@workspace"],
    subject: "Review the handoff",
    inReplyTo: "m-41",
    body: "Please inspect the adapter.\nReply with findings.",
  })).toBe([
    "[cmux-agent-message]",
    "message-id: m-42",
    "thread-id: t-7",
    "from: claude@workspace",
    "to: codex@workspace, review@workspace",
    "subject: Review the handoff",
    "in-reply-to: m-41",
    "body:",
    "Please inspect the adapter.",
    "Reply with findings.",
    "[/cmux-agent-message]",
  ].join("\n"));
});

test("keeps message bodies verbatim and folds header newlines", () => {
  expect(acpPromptFromMail({
    id: "m\n42",
    threadId: "t\r7",
    sender: "claude\nworkspace",
    recipients: ["codex\rworkspace"],
    subject: "Review\r\nnow",
    body: "line 1\r\nline 2",
  })).toContain("message-id: m 42\nthread-id: t 7\nfrom: claude workspace\nto: codex workspace\nsubject: Review now\nbody:\nline 1\r\nline 2");
});
