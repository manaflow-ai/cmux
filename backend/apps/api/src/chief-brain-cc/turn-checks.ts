/**
 * What a Chief checks at the start and end of each turn (Leo, 2026-11-24: agents are not ambitious enough, patch instead of
 * fixing the cause, don't think outside the box, "especially at the beginnings and ends of turns"). The source of truth is
 * Native/OptChat/chief-kernel/src/turn_checks.md (the local Chief's `chief_kernel::TURN_CHECKS`); the Worker bundles no text
 * files, so this is its copy, and test-node/turn-checks.test.ts fails when the two differ.
 */
export const TURN_CHECKS = `Before your first move: name the whole space this request is one case of and start all of it, in parallel. Ask why it happened and remove the cause; never route around it. Take the direct way (the real app, a machine or tool you already have, or deleting the need) over a probe, a proxy or a question.
Before any report, interim ones too: line one says whether it is fixed at the cause or patched. Then write the person's likely next message ("why not all of them", "why not now", "why did it happen at all") and start that work before you send. Any wait you leave has a waker and a deadline.`

/** A turn's prompt with the checks as its last block: the newest words the turn reads, never in the cached system prompt. */
export const withTurnChecks = (prompt: string): string => `${prompt}\n\n<turn-checks>\n${TURN_CHECKS}\n</turn-checks>`
