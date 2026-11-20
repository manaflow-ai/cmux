import { useState } from "react";
import { agentChatText } from "../i18n";
import type { AgentQuestionItem, PendingQuestion } from "../session";

// A question the agent waits on (Codex request_user_input): each item takes
// one option or, where it allows, typed text. Answer sends every item's
// answer at once; Decline lets the agent go on without one.

const OTHER = "\u0000other";

// Question ids are the agent's own strings: `constructor` or `__proto__` must
// read as unset, never as an inherited property.
function own(record: Record<string, string>, id: string): string | undefined {
  return Object.hasOwn(record, id) ? record[id] : undefined;
}

/** Each item's answer, or null while one is still missing. */
export function questionAnswers(
  items: AgentQuestionItem[],
  choices: Record<string, string>,
  typed: Record<string, string>,
): Record<string, string> | null {
  const answers: Record<string, string> = Object.create(null);
  for (const item of items) {
    const choice = item.options.length ? own(choices, item.id) : OTHER;
    const answer = choice === OTHER ? own(typed, item.id) ?? "" : choice;
    if (!answer?.trim()) return null;
    answers[item.id] = answer;
  }
  return answers;
}

/** The card's React key: a new attempt (a reconnect, or a refused answer)
 * remounts it, so a question still waiting takes input again after an
 * answer that may never have reached the server. */
export function questionCardKey(question: PendingQuestion, attempt: number): string {
  return `${question.questionId}:${attempt}`;
}

export function QuestionCard({ question, onAnswer }: {
  question: PendingQuestion;
  onAnswer(questionId: string, answers: Record<string, string> | null): boolean;
}) {
  const [choices, setChoices] = useState<Record<string, string>>({});
  const [typed, setTyped] = useState<Record<string, string>>({});
  const [sent, setSent] = useState(false);
  const answers = questionAnswers(question.items, choices, typed);
  const send = (value: Record<string, string> | null) => {
    if (!sent && onAnswer(question.questionId, value)) setSent(true);
  };

  return (
    <form
      className="agent-question"
      id="agent-question"
      aria-label={agentChatText("questionHeading")}
      onSubmit={(e) => {
        e.preventDefault();
        if (answers) send(answers);
      }}
    >
      <div className="agent-question-heading">{agentChatText("questionHeading")}</div>
      {question.items.map((item) => (
        <fieldset className="agent-question-item" key={item.id} disabled={sent}>
          {item.header ? <legend className="agent-question-header">{item.header}</legend> : null}
          <div className="agent-question-text">{item.question}</div>
          {item.options.length ? (
            <div className="agent-question-options" role="radiogroup" aria-label={item.header ?? item.question}>
              {item.options.map((option) => (
                <button
                  key={option.label}
                  type="button"
                  role="radio"
                  aria-checked={own(choices, item.id) === option.label}
                  className="agent-question-option"
                  onClick={() => setChoices((c) => ({ ...c, [item.id]: option.label }))}
                >
                  <span className="agent-question-option-label">{option.label}</span>
                  {option.description ? <span className="agent-question-option-detail">{option.description}</span> : null}
                </button>
              ))}
            </div>
          ) : null}
          {item.allowsOther ? (
            <input
              className="agent-question-input"
              type={item.secret ? "password" : "text"}
              autoComplete="off"
              aria-label={item.header ?? item.question}
              placeholder={agentChatText(item.options.length ? "questionOther" : "questionTypeAnswer")}
              value={own(typed, item.id) ?? ""}
              onFocus={() => {
                if (item.options.length) setChoices((c) => ({ ...c, [item.id]: OTHER }));
              }}
              onChange={(e) => {
                const value = e.target.value;
                setTyped((t) => ({ ...t, [item.id]: value }));
                if (item.options.length) setChoices((c) => ({ ...c, [item.id]: OTHER }));
              }}
            />
          ) : null}
        </fieldset>
      ))}
      <div className="agent-question-actions">
        <button type="button" className="agent-question-decline" disabled={sent} onClick={() => send(null)}>
          {agentChatText("questionDecline")}
        </button>
        <button type="submit" className="agent-question-submit" disabled={sent || !answers}>
          {agentChatText("questionAnswer")}
        </button>
      </div>
    </form>
  );
}
