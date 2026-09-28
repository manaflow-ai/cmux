import { InMemoryMailBroker, MailConflictError, MailFanoutError, MailUnknownParentError, createMail } from "../mail";
import { test } from "bun:test";

test("mail broker append, threading, delivery, and fan-out", () => {
const broker = new InMemoryMailBroker();
const events: string[] = [];
const unsubscribe = broker.subscribe("claude", (event) => {
  events.push(event.kind);
});

const root = broker.append({
  id: "m-root",
  sender: "codex",
  recipients: ["claude", "codex"],
  subject: "Review",
  body: "Please review the change.",
  createdAt: 100,
});
if (!root.created || root.duplicate || root.envelope.threadId !== "m-root") throw new Error("root append should create a new thread");
if (root.deliveries.length !== 2 || root.deliveries.some((delivery) => delivery.state !== "queued")) {
  throw new Error("each recipient should receive a queued delivery receipt");
}
if (events.length !== 1 || events[0] !== "appended") throw new Error(`recipient listener should see append once: ${events}`);

const duplicate = broker.append({
  id: "m-root",
  sender: "codex",
  recipients: ["claude", "codex"],
  subject: "Review",
  body: "Please review the change.",
  createdAt: 100,
});
if (duplicate.created || !duplicate.duplicate || duplicate.envelope !== root.envelope) {
  throw new Error("replaying the same message should be idempotent");
}

try {
  broker.append({ id: "m-root", sender: "codex", recipients: ["claude"], body: "tampered" });
  throw new Error("same id with different content should fail");
} catch (error) {
  if (!(error instanceof MailConflictError)) throw error;
}

const delivered = broker.markDelivered("m-root", "claude");
if (delivered.state !== "delivered" || delivered.attempts !== 1) throw new Error("delivery should record attempts");
const acknowledged = broker.acknowledge("m-root", "claude");
if (acknowledged.state !== "acknowledged" || acknowledged.attempts !== 1) throw new Error("ack should preserve attempts");
if (broker.inbox("claude", { state: "acknowledged" }).length !== 1) throw new Error("inbox state filtering failed");
if (events.join(",") !== "appended,delivery,delivery") throw new Error(`delivery events missing: ${events}`);

const reply = broker.reply("m-root", {
  id: "m-reply",
  sender: "claude",
  recipients: ["codex"],
  body: "Looks good.",
  createdAt: 200,
});
if (reply.envelope.threadId !== "m-root" || reply.envelope.kind !== "reply" || reply.envelope.references[0] !== "m-root") {
  throw new Error(`reply should inherit thread and ancestry: ${JSON.stringify(reply.envelope)}`);
}
if (broker.thread("m-root").length !== 2) throw new Error("thread should contain root and reply");

const plain = createMail({ sender: "a", recipients: ["b"], body: "hello", metadata: { z: 1 } });
if (!plain.id || plain.threadId !== plain.id || plain.contentType !== "text/plain") throw new Error("createMail defaults failed");
const immutable = broker.append({
  id: "immutable",
  sender: "a",
  recipients: ["b"],
  body: "hello",
  attachments: [{ uri: "artifact://one" }],
  metadata: { nested: { value: 1 }, list: [{ ok: true }] },
});
if (!Object.isFrozen(immutable.envelope.attachments[0]) || !Object.isFrozen(immutable.envelope.metadata.nested)) {
  throw new Error("nested envelope data should be immutable");
}
unsubscribe();

const capped = new InMemoryMailBroker({ maxRecipients: 2 });
try {
  capped.append({ id: "too-many", sender: "a", recipients: ["b", "c", "d"], body: "hello" });
  throw new Error("fan-out cap should reject oversized messages");
} catch (error) {
  if (!(error instanceof MailFanoutError) || error.limit !== 2 || error.recipientCount !== 3) throw error;
}
const deadLetter = capped.append({ id: "failed", sender: "a", recipients: ["b"], body: "hello" });
const dead = capped.updateDelivery(deadLetter.envelope.id, "b", { state: "dead-lettered", error: "transport stopped" });
if (dead.state !== "dead-lettered" || dead.error !== "transport stopped") throw new Error("dead-letter delivery state should be retained");

const listenerBroker = new InMemoryMailBroker();
let listenerCount = 0;
let listenerFailures = 0;
listenerBroker.onError(() => { listenerFailures += 1; });
listenerBroker.subscribe("b", () => { throw new Error("listener failed"); });
listenerBroker.subscribe("b", () => { listenerCount += 1; });
const listenerAppend = listenerBroker.append({ id: "listener", sender: "a", recipients: ["b"], body: "hello" });
if (!listenerAppend.created || listenerCount !== 1 || listenerFailures !== 1 || !listenerBroker.get("listener")) {
  throw new Error("listener failures should not mask committed appends");
}

const invalidBroker = new InMemoryMailBroker();
const circular: Record<string, unknown> = {};
circular.self = circular;
try {
  invalidBroker.append({ id: "invalid", sender: "a", recipients: ["b"], body: "hello", metadata: circular as never });
  throw new Error("circular metadata should be rejected");
} catch (error) {
  if (!(error instanceof Error) || !error.message.includes("circular")) throw error;
}
if (invalidBroker.get("invalid") || invalidBroker.list().length !== 0) throw new Error("invalid metadata must not partially commit");
console.log("mail broker assertions passed");
});

test("append refuses a reply to a parent it has never seen", () => {
  const broker = new InMemoryMailBroker();
  // reply() already refuses this. append() is the primitive underneath it, so
  // letting the same input through here roots a second thread at the reply's
  // own id: the reply claims kind "reply" but thread(parentId) never returns it.
  try {
    broker.append({ id: "orphan", sender: "claude", recipients: ["codex"], body: "Looks good.", inReplyTo: "never-appended" });
    throw new Error("append should refuse a reply whose parent this broker has never seen");
  } catch (error) {
    // Match the class, not the text: updateDelivery throws its own Error for an
    // unknown message id, so a substring match could pass for the wrong reason.
    if (!(error instanceof MailUnknownParentError) || error.parentMessageId !== "never-appended") throw error;
  }
  if (broker.get("orphan") || broker.list().length !== 0) throw new Error("a refused reply must not partially commit");

  // createMail normalizes with no broker to look the parent up in, so it roots
  // the orphan at its own id and hands append a threadId that looks explicit.
  // That is the same broken envelope, so append has to refuse it too.
  try {
    broker.append(createMail({ id: "orphan-prebuilt", sender: "claude", recipients: ["codex"], body: "Looks good.", inReplyTo: "never-appended" }));
    throw new Error("append should refuse a prebuilt reply whose thread is its own id");
  } catch (error) {
    if (!(error instanceof MailUnknownParentError) || error.parentMessageId !== "never-appended") throw error;
  }
  if (broker.get("orphan-prebuilt") || broker.list().length !== 0) throw new Error("a refused prebuilt reply must not partially commit");

  // A blank threadId is not the context a federated reply needs either.
  try {
    broker.append({ id: "orphan-blank", threadId: "  ", sender: "claude", recipients: ["codex"], body: "Looks good.", inReplyTo: "never-appended" });
    throw new Error("append should refuse a reply whose threadId is blank");
  } catch (error) {
    if (!(error instanceof MailUnknownParentError)) throw error;
  }

  // A caller that names the thread carries the context this broker lacks, so a
  // reply forwarded from another broker still appends and stays in its thread.
  const federated = broker.append({
    id: "federated",
    threadId: "thread-remote",
    sender: "claude",
    recipients: ["codex"],
    body: "Looks good.",
    inReplyTo: "never-appended",
  });
  if (federated.envelope.threadId !== "thread-remote" || federated.envelope.kind !== "reply") {
    throw new Error(`an explicit threadId should carry a federated reply: ${JSON.stringify(federated.envelope)}`);
  }
  if (broker.list({ threadId: "thread-remote" }).length !== 1) throw new Error("the federated reply should be listed under its thread");
  console.log("mail unknown-parent assertions passed");
});

test("append stays idempotent when a retry reorders the recipients", () => {
  const broker = new InMemoryMailBroker();
  const input = { id: "fanout", sender: "codex", subject: "Review", body: "Please review.", createdAt: 100 };
  const first = broker.append({ ...input, recipients: ["claude", "codex"] });
  // Recipients are a set: the broker dedupes them and keys deliveries by
  // address. A retry that lists the same set in another order is the same
  // message, so it must not look like someone tampered with the id.
  const retry = broker.append({ ...input, recipients: ["codex", "claude"] });
  if (retry.created || !retry.duplicate || retry.envelope !== first.envelope) {
    throw new Error("a retry that reorders recipients should be an idempotent no-op");
  }
  if (first.envelope.recipients.join(",") !== "claude,codex") {
    throw new Error(`the stored envelope should keep the first append's order: ${first.envelope.recipients}`);
  }

  // Changing the recipient set is still a conflict.
  try {
    broker.append({ ...input, recipients: ["claude"] });
    throw new Error("dropping a recipient should still conflict");
  } catch (error) {
    if (!(error instanceof MailConflictError)) throw error;
  }
  console.log("mail recipient-order assertions passed");
});

export {};
