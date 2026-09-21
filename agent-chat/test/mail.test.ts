import { InMemoryMailBroker, MailConflictError, MailFanoutError, createMail } from "../mail";
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

const reply = broker.append({
  id: "m-reply",
  sender: "claude",
  recipients: ["codex"],
  inReplyTo: "m-root",
  body: "Looks good.",
  createdAt: 200,
});
if (reply.envelope.threadId !== "m-root" || reply.envelope.kind !== "reply" || reply.envelope.references[0] !== "m-root") {
  throw new Error(`reply should inherit thread and ancestry: ${JSON.stringify(reply.envelope)}`);
}
if (broker.thread("m-root").length !== 2) throw new Error("thread should contain root and reply");

const plain = createMail({ sender: "a", recipients: ["b"], body: "hello", metadata: { z: 1 } });
if (!plain.id || plain.threadId !== plain.id || plain.contentType !== "text/plain") throw new Error("createMail defaults failed");
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
console.log("mail broker assertions passed");
});

export {};
