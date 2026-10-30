import { expect, test } from "bun:test";
import { codexAdapter, codexSessionForTest } from "../adapters/codex";
import { parseQuestionAnswers } from "../server";
import { applyQuestionEvent, pendingQuestions, type AgentEvent } from "../src/session";
import { questionAnswers, questionCardKey } from "../src/components/QuestionCard";

const threadId = "thread-parity";

// Shaped like `codex app-server generate-json-schema`'s ToolRequestUserInputParams.
function ask(id: number | string, questions: unknown[], itemId = "item-1") {
  return {
    id,
    method: "item/tool/requestUserInput",
    params: { threadId, turnId: "turn-1", itemId, isBlocking: true, questions },
  };
}

const engine = {
  id: "db_engine",
  header: "Database",
  question: "Which database should the service use?",
  isOther: true,
  options: [
    { label: "Postgres", description: "Managed Postgres with point-in-time restore." },
    { label: "SQLite", description: "" },
  ],
};
const name = { id: "service_name", header: "Name", question: "What should the service be called?", options: null };
const token = { id: "token", header: "Token", question: "Paste the deploy token", isSecret: true, options: null };
const region = { id: "region", header: "Region", question: "Which region?", options: [{ label: "us", description: "" }, { label: "eu", description: "" }] };

test("a Codex user-input request becomes a question for the person, not a decline", () => {
  const h = codexSessionForTest();
  h.feed([ask(7, [engine, name])]);

  expect(h.writes).toEqual([]);
  expect(h.events).toEqual([{
    kind: "question",
    questionId: "codex-item-1",
    items: [
      {
        id: "db_engine",
        header: "Database",
        question: "Which database should the service use?",
        options: [
          { label: "Postgres", description: "Managed Postgres with point-in-time restore." },
          { label: "SQLite" },
        ],
        allowsOther: true,
        secret: false,
      },
      { id: "service_name", header: "Name", question: "What should the service be called?", options: [], allowsOther: true, secret: false },
    ],
  }]);
});

test("the person's answers go back to Codex keyed by question id", () => {
  const h = codexSessionForTest();
  h.feed([ask(7, [engine, name])]);
  codexAdapter.answerQuestion!(h.sess, "codex-item-1", { db_engine: "Postgres", service_name: "billing" });

  expect(h.writes).toEqual([{
    jsonrpc: "2.0",
    id: 7,
    result: { answers: { db_engine: { answers: ["Postgres"] }, service_name: { answers: ["billing"] } } },
  }]);
  expect(h.events.slice(1)).toEqual([
    { kind: "question-resolved", questionId: "codex-item-1", outcome: "answered" },
    { kind: "status", text: "answered: Database: Postgres · Name: billing" },
  ]);
  // Codex confirms with serverRequest/resolved; nothing is left to settle.
  h.feed([{ method: "serverRequest/resolved", params: { threadId, requestId: 7 } }]);
  expect(h.events).toHaveLength(3);
  expect(() => codexAdapter.answerQuestion!(h.sess, "codex-item-1", { db_engine: "SQLite", service_name: "x" })).toThrow(
    "no longer waiting",
  );
});

test("an answer the question does not accept is refused and the question stays open", () => {
  const h = codexSessionForTest();
  h.feed([ask(8, [region])]);
  expect(() => codexAdapter.answerQuestion!(h.sess, "codex-item-1", { region: "mars" })).toThrow("Region takes only its options: us, eu");
  expect(() => codexAdapter.answerQuestion!(h.sess, "codex-item-1", {})).toThrow("Region needs an answer");
  expect(() => codexAdapter.answerQuestion!(h.sess, "codex-item-1", { region: "us", extra: "x" })).toThrow("no question extra");
  expect(h.writes).toEqual([]);
  codexAdapter.answerQuestion!(h.sess, "codex-item-1", { region: "eu" });
  expect(h.writes).toEqual([{ jsonrpc: "2.0", id: 8, result: { answers: { region: { answers: ["eu"] } } } }]);
});

test("a secret answer reaches Codex but never the transcript", () => {
  const h = codexSessionForTest();
  h.feed([ask(9, [token])]);
  codexAdapter.answerQuestion!(h.sess, "codex-item-1", { token: "s3cr3t" });
  expect(h.writes).toEqual([{ jsonrpc: "2.0", id: 9, result: { answers: { token: { answers: ["s3cr3t"] } } } }]);
  expect(JSON.stringify(h.events)).not.toContain("s3cr3t");
  expect(h.events.at(-1)).toEqual({ kind: "status", text: "answered: Token: (hidden)" });
});

test("declining, Stop, Codex settling it, and the turn ending each close the question once", () => {
  const declined = codexSessionForTest();
  declined.feed([ask(10, [region])]);
  codexAdapter.answerQuestion!(declined.sess, "codex-item-1", null);
  expect(declined.writes).toEqual([{ jsonrpc: "2.0", id: 10, result: { answers: {} } }]);
  expect(declined.events.at(-1)).toEqual({ kind: "question-resolved", questionId: "codex-item-1", outcome: "declined" });

  const stopped = codexSessionForTest();
  stopped.feed([ask(11, [region])]);
  codexAdapter.stop(stopped.sess);
  expect(stopped.writes).toEqual([{ jsonrpc: "2.0", id: 11, result: { answers: {} } }]);
  expect(stopped.events.at(-1)).toEqual({ kind: "question-resolved", questionId: "codex-item-1", outcome: "declined" });

  const settled = codexSessionForTest();
  settled.feed([ask("req-12", [region]), { method: "serverRequest/resolved", params: { threadId, requestId: "req-12" } }]);
  expect(settled.writes).toEqual([]);
  expect(settled.events.at(-1)).toEqual({ kind: "question-resolved", questionId: "codex-item-1", outcome: "resolved" });

  const ended = codexSessionForTest();
  ended.feed([
    { method: "turn/started", params: { threadId, turn: { id: "turn-1" } } },
    ask(13, [region]),
    { method: "turn/completed", params: { threadId, turn: { id: "turn-1" } } },
  ]);
  expect(ended.writes).toEqual([]);
  expect(ended.events.map((e) => e.kind)).toEqual(["question", "question-resolved", "done"]);
  expect(ended.events[1]).toEqual({ kind: "question-resolved", questionId: "codex-item-1", outcome: "expired" });
});

test("a request with nothing answerable is declined so the turn goes on", () => {
  const h = codexSessionForTest();
  h.feed([ask(14, [{ header: "no id", question: "?" }])]);
  expect(h.writes).toEqual([{ jsonrpc: "2.0", id: 14, result: { answers: {} } }]);
  expect(h.events).toEqual([{ kind: "status", text: "declined a Codex question with no answerable items" }]);
});

test("the chat derives waiting questions from history and live events", () => {
  const item = { id: "region", question: "Which region?", options: [{ label: "us" }], allowsOther: false, secret: false };
  const events: AgentEvent[] = [
    { kind: "question", questionId: "a", items: [item] },
    { kind: "question", questionId: "b", items: [item] },
    { kind: "question-resolved", questionId: "a", outcome: "answered" },
  ];
  expect(pendingQuestions(events).map((q) => q.questionId)).toEqual(["b"]);
  expect(applyQuestionEvent(pendingQuestions(events), { kind: "question-resolved", questionId: "b", outcome: "expired" })).toEqual([]);
});

test("the card sends one answer per item, typed text only where the item allows it", () => {
  const items = [
    { id: "db", question: "DB?", options: [{ label: "Postgres" }], allowsOther: true, secret: false },
    { id: "name", question: "Name?", options: [], allowsOther: true, secret: false },
  ];
  expect(questionAnswers(items, { db: "Postgres" }, {})).toBeNull();
  expect(questionAnswers(items, { db: "Postgres" }, { name: "billing" })).toEqual({ db: "Postgres", name: "billing" });
  expect(questionAnswers(items, { db: "\u0000other" }, { db: "MySQL", name: "billing" })).toEqual({ db: "MySQL", name: "billing" });
  expect(questionAnswers(items, { db: "\u0000other" }, { db: "  ", name: "billing" })).toBeNull();
});

test("a reconnect or a refused answer gives a still-waiting question a fresh card", () => {
  const question = { questionId: "codex-item-1", items: [] };
  expect(questionCardKey(question, 1)).not.toBe(questionCardKey(question, 2));
  expect(questionCardKey(question, 2)).toBe(questionCardKey({ ...question }, 2));
});

test("the answer op accepts a decline or string answers only", () => {
  expect(parseQuestionAnswers(null)).toBeNull();
  expect(parseQuestionAnswers({ region: "us" })).toEqual({ region: "us" });
  expect(parseQuestionAnswers({ region: ["us"] })).toBeUndefined();
  expect(parseQuestionAnswers(["us"])).toBeUndefined();
  expect(parseQuestionAnswers(undefined)).toBeUndefined();
});
