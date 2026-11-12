import { appendFile, mkdir, readFile } from "node:fs/promises";
import { dirname } from "node:path";
import {
  InMemoryMailBroker,
  type DeliveryReceipt,
  type DeliveryUpdate,
  type InMemoryMailBrokerOptions,
  type MailAppendResult,
  type MailEnvelope,
  type MailId,
  type MailInput,
  type AgentAddress,
  type MailListener,
  type MailErrorListener,
  type ThreadId,
} from "./core";

type JournalRecord =
  | { readonly kind: "message"; readonly envelope: MailEnvelope; readonly deliveries: readonly DeliveryReceipt[] }
  | { readonly kind: "delivery"; readonly receipt: DeliveryReceipt };

/**
 * Append-only mailbox persistence for local ACP sessions.
 *
 * The journal is authoritative for committed messages and delivery states;
 * listeners and WebSockets remain wake-up hints. `open` replays complete
 * records before returning, so a reconnect can inspect queued mail safely.
 */
export class JsonlMailJournal {
  readonly path: string;
  private readonly broker: InMemoryMailBroker;
  private writeChain: Promise<void> = Promise.resolve();
  private writeFailure: Error | undefined;

  private constructor(path: string, broker: InMemoryMailBroker) {
    this.path = path;
    this.broker = broker;
  }

  static async open(path: string, options: InMemoryMailBrokerOptions = {}): Promise<JsonlMailJournal> {
    const broker = new InMemoryMailBroker(options);
    const journal = new JsonlMailJournal(path, broker);
    let contents = "";
    try {
      contents = await readFile(path, "utf8");
    } catch (error: any) {
      if (error?.code !== "ENOENT") throw error;
    }
    for (const [index, line] of contents.split(/\r?\n/).entries()) {
      if (!line.trim()) continue;
      let record: JournalRecord;
      try {
        record = parseRecord(JSON.parse(line));
        if (record.kind === "message") broker.restore(record.envelope, record.deliveries);
        else broker.restoreDelivery(record.receipt);
      } catch (error) {
        throw new Error(`invalid mail journal record at line ${index + 1}: ${error instanceof Error ? error.message : String(error)}`);
      }
    }
    return journal;
  }

  append(input: MailInput | MailEnvelope): MailAppendResult {
    this.assertWritable();
    const result = this.broker.append(input);
    if (result.created) {
      this.enqueue({ kind: "message", envelope: result.envelope, deliveries: result.deliveries });
    }
    return result;
  }

  /** Semantic alias for callers that use publish terminology. */
  publish(input: MailInput | MailEnvelope): MailAppendResult {
    return this.append(input);
  }

  updateDelivery(messageId: MailId, recipient: AgentAddress, update: DeliveryUpdate): DeliveryReceipt {
    this.assertWritable();
    const receipt = this.broker.updateDelivery(messageId, recipient, update);
    this.enqueue({ kind: "delivery", receipt });
    return receipt;
  }

  markDelivered(messageId: MailId, recipient: AgentAddress): DeliveryReceipt {
    return this.updateDelivery(messageId, recipient, { state: "delivered" });
  }

  acknowledge(messageId: MailId, recipient: AgentAddress): DeliveryReceipt {
    return this.updateDelivery(messageId, recipient, { state: "acknowledged" });
  }

  markActed(messageId: MailId, recipient: AgentAddress): DeliveryReceipt {
    return this.updateDelivery(messageId, recipient, { state: "acted" });
  }

  markReplied(messageId: MailId, recipient: AgentAddress): DeliveryReceipt {
    return this.updateDelivery(messageId, recipient, { state: "replied" });
  }

  reply(parentMessageId: MailId, input: Omit<MailInput, "inReplyTo" | "threadId">): MailAppendResult {
    this.assertWritable();
    const result = this.broker.reply(parentMessageId, input);
    if (result.created) this.enqueue({ kind: "message", envelope: result.envelope, deliveries: result.deliveries });
    return result;
  }

  inbox(...args: Parameters<InMemoryMailBroker["inbox"]>): ReturnType<InMemoryMailBroker["inbox"]> {
    return this.broker.inbox(...args);
  }

  /** Read-only broker projections; mutations must go through this journal. */
  get(messageId: MailId): MailEnvelope | undefined {
    return this.broker.get(messageId);
  }

  getDelivery(messageId: MailId, recipient: AgentAddress): DeliveryReceipt | undefined {
    return this.broker.getDelivery(messageId, recipient);
  }

  list(options: { readonly threadId?: ThreadId } = {}): MailEnvelope[] {
    return this.broker.list(options);
  }

  thread(threadId: ThreadId): MailEnvelope[] {
    return this.broker.thread(threadId);
  }

  subscribe(recipient: AgentAddress, listener: MailListener): () => void {
    return this.broker.subscribe(recipient, listener);
  }

  onError(listener: MailErrorListener): () => void {
    return this.broker.onError(listener);
  }

  /** Wait until all accepted writes have reached the journal file. */
  async flush(): Promise<void> {
    await this.writeChain;
  }

  private enqueue(record: JournalRecord): void {
    this.assertWritable();
    const line = `${JSON.stringify(record)}\n`;
    this.writeChain = this.writeChain.catch(() => undefined).then(async () => {
      try {
        await mkdir(dirname(this.path), { recursive: true });
        await appendFile(this.path, line, "utf8");
      } catch (error) {
        this.writeFailure = error instanceof Error ? error : new Error(String(error));
        throw this.writeFailure;
      }
    });
  }

  private assertWritable(): void {
    if (this.writeFailure) throw new Error(`mail journal is unavailable: ${this.writeFailure.message}`);
  }
}

function parseRecord(value: unknown): JournalRecord {
  if (!isRecord(value) || (value.kind !== "message" && value.kind !== "delivery")) throw new Error("record kind is invalid");
  if (value.kind === "message") {
    if (!isRecord(value.envelope) || !Array.isArray(value.deliveries)) throw new Error("message record is malformed");
    const deliveries = value.deliveries.map(parseReceipt);
    return { kind: "message", envelope: parseEnvelope(value.envelope), deliveries };
  }
  return { kind: "delivery", receipt: parseReceipt(value.receipt) };
}

function parseEnvelope(value: Record<string, unknown>): MailEnvelope {
  const kinds = ["message", "request", "reply", "event"];
  if (typeof value.id !== "string" || !value.id.trim() ||
      typeof value.threadId !== "string" || !value.threadId.trim() ||
      typeof value.kind !== "string" || !kinds.includes(value.kind) ||
      typeof value.sender !== "string" || !value.sender.trim() ||
      !Array.isArray(value.recipients) || value.recipients.length === 0 ||
      value.recipients.some((recipient) => typeof recipient !== "string" || !recipient.trim()) ||
      typeof value.body !== "string" ||
      typeof value.contentType !== "string" || !value.contentType.trim() ||
      typeof value.createdAt !== "number" || !Number.isFinite(value.createdAt) ||
      !Array.isArray(value.references) || value.references.some((reference) => typeof reference !== "string") ||
      !Array.isArray(value.attachments) || value.attachments.some((attachment) => !isAttachment(attachment)) ||
      !isRecord(value.metadata)) {
    throw new Error("mail envelope is malformed");
  }
  if (value.subject !== undefined && typeof value.subject !== "string") throw new Error("mail envelope is malformed");
  if (value.inReplyTo !== undefined && (typeof value.inReplyTo !== "string" || !value.inReplyTo.trim())) {
    throw new Error("mail envelope is malformed");
  }
  return value as unknown as MailEnvelope;
}

function isAttachment(value: unknown): boolean {
  if (!isRecord(value) || typeof value.uri !== "string" || !value.uri.trim()) return false;
  return ["name", "mediaType", "sha256"].every((key) => value[key] === undefined || typeof value[key] === "string");
}

function parseReceipt(value: unknown): DeliveryReceipt {
  if (!isRecord(value) || typeof value.messageId !== "string" || !value.messageId.trim() ||
      typeof value.recipient !== "string" || !value.recipient.trim() ||
      typeof value.state !== "string" || !["queued", "delivered", "acknowledged", "acted", "replied", "failed", "dead-lettered"].includes(value.state) ||
      !Number.isInteger(value.attempts) || (value.attempts as number) < 0 || !Number.isFinite(value.updatedAt) ||
      (value.error !== undefined && typeof value.error !== "string")) {
    throw new Error("delivery receipt is malformed");
  }
  return value as unknown as DeliveryReceipt;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return Boolean(value) && typeof value === "object" && !Array.isArray(value);
}

