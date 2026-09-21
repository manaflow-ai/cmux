/**
 * A small provider-neutral mailbox primitive.
 *
 * The broker deliberately has no process, socket, or agent-provider concerns.
 * Adapters can append envelopes to it and use the delivery receipts to drive
 * ACP, A2A, or another transport.
 */

export type MailId = string;
export type ThreadId = string;
export type AgentAddress = string;

export type MailKind = "message" | "request" | "reply" | "event";

/** State for one recipient of one message. */
export type DeliveryState = "queued" | "delivered" | "acknowledged" | "acted" | "replied" | "failed" | "dead-lettered";

export interface MailAttachment {
  readonly uri: string;
  readonly name?: string;
  readonly mediaType?: string;
  readonly sha256?: string;
}

/**
 * The durable unit of mail. `id` is the idempotency key and `threadId` groups
 * the complete conversation. A reply should carry `inReplyTo`; `references`
 * is available for clients which need RFC-5322-like ancestry.
 */
export interface MailEnvelope {
  readonly id: MailId;
  readonly threadId: ThreadId;
  readonly kind: MailKind;
  readonly sender: AgentAddress;
  readonly recipients: readonly AgentAddress[];
  readonly subject?: string;
  readonly body: string;
  readonly contentType: string;
  readonly createdAt: number;
  readonly inReplyTo?: MailId;
  readonly references: readonly MailId[];
  readonly attachments: readonly MailAttachment[];
  readonly metadata: Readonly<Record<string, unknown>>;
}

export interface MailInput {
  readonly id?: MailId;
  readonly threadId?: ThreadId;
  readonly kind?: MailKind;
  readonly sender: AgentAddress;
  readonly recipients: readonly AgentAddress[];
  readonly subject?: string;
  readonly body: string;
  readonly contentType?: string;
  readonly createdAt?: number;
  readonly inReplyTo?: MailId;
  readonly references?: readonly MailId[];
  readonly attachments?: readonly MailAttachment[];
  readonly metadata?: Readonly<Record<string, unknown>>;
}

export interface DeliveryReceipt {
  readonly messageId: MailId;
  readonly recipient: AgentAddress;
  readonly state: DeliveryState;
  readonly attempts: number;
  readonly updatedAt: number;
  readonly error?: string;
}

export interface MailAppendResult {
  readonly envelope: MailEnvelope;
  readonly deliveries: readonly DeliveryReceipt[];
  /** True when this call inserted a new envelope. */
  readonly created: boolean;
  /** True when an existing envelope with the same id was returned. */
  readonly duplicate: boolean;
}

export interface DeliveryUpdate {
  readonly state: DeliveryState;
  readonly error?: string;
}

export interface InboxOptions {
  readonly state?: DeliveryState;
  readonly threadId?: ThreadId;
}

export type MailEvent =
  | { readonly kind: "appended"; readonly envelope: MailEnvelope; readonly deliveries: readonly DeliveryReceipt[] }
  | { readonly kind: "delivery"; readonly envelope: MailEnvelope; readonly delivery: DeliveryReceipt };

export type MailListener = (event: MailEvent) => void;

export class MailConflictError extends Error {
  readonly code = "MAIL_ID_CONFLICT" as const;
  readonly messageId: MailId;

  constructor(messageId: MailId) {
    super(`mail id ${messageId} was already appended with different content`);
    this.name = "MailConflictError";
    this.messageId = messageId;
  }
}

export class MailFanoutError extends Error {
  readonly code = "MAIL_FANOUT_LIMIT" as const;
  readonly recipientCount: number;
  readonly limit: number;

  constructor(recipientCount: number, limit: number) {
    super(`mail has ${recipientCount} recipients; fan-out limit is ${limit}`);
    this.name = "MailFanoutError";
    this.recipientCount = recipientCount;
    this.limit = limit;
  }
}

export interface InMemoryMailBrokerOptions {
  /** Maximum distinct recipients allowed for one envelope. Defaults to 64. */
  readonly maxRecipients?: number;
  /** Alias accepted by callers that refer to this as a fan-out limit. */
  readonly maxFanOut?: number;
}

export class InMemoryMailBroker {
  readonly maxRecipients: number;
  private readonly messagesById = new Map<MailId, MailEnvelope>();
  private readonly fingerprintsById = new Map<MailId, string>();
  private readonly deliveriesByMessage = new Map<MailId, Map<AgentAddress, DeliveryReceipt>>();
  private readonly listenersByRecipient = new Map<AgentAddress, Set<MailListener>>();
  private readonly appendOrder: MailId[] = [];

  constructor(options: InMemoryMailBrokerOptions = {}) {
    this.maxRecipients = options.maxRecipients ?? options.maxFanOut ?? 64;
    if (!Number.isInteger(this.maxRecipients) || this.maxRecipients < 1) {
      throw new Error("mail fan-out limit must be a positive integer");
    }
  }

  /** Append once. Re-appending an identical id is a safe, idempotent no-op. */
  append(input: MailInput | MailEnvelope): MailAppendResult {
    const replyParent = input.inReplyTo ? this.messagesById.get(input.inReplyTo) : undefined;
    const envelope = normalizeEnvelope(input, (input as MailInput).threadId ?? replyParent?.threadId);
    if (envelope.recipients.length > this.maxRecipients) throw new MailFanoutError(envelope.recipients.length, this.maxRecipients);
    const existing = this.messagesById.get(envelope.id);
    if (existing) {
      const exact = this.fingerprintsById.get(envelope.id) === fingerprint(envelope);
      // A caller can safely retry an input which omitted `createdAt`; the
      // broker generated that value on the first attempt.
      const generatedTimestampMatches = input.createdAt === undefined && fingerprint({ ...envelope, createdAt: existing.createdAt }) === fingerprint(existing);
      if (!exact && !generatedTimestampMatches) throw new MailConflictError(envelope.id);
      return {
        envelope: existing,
        deliveries: this.deliveryList(envelope.id),
        created: false,
        duplicate: true,
      };
    }

    this.messagesById.set(envelope.id, envelope);
    this.fingerprintsById.set(envelope.id, fingerprint(envelope));
    this.appendOrder.push(envelope.id);
    const byRecipient = new Map<AgentAddress, DeliveryReceipt>();
    const deliveries: DeliveryReceipt[] = [];
    for (const recipient of envelope.recipients) {
      const receipt: DeliveryReceipt = {
        messageId: envelope.id,
        recipient,
        state: "queued",
        attempts: 0,
        updatedAt: envelope.createdAt,
      };
      byRecipient.set(recipient, receipt);
      deliveries.push(receipt);
    }
    this.deliveriesByMessage.set(envelope.id, byRecipient);
    this.emit({ kind: "appended", envelope, deliveries });
    return { envelope, deliveries, created: true, duplicate: false };
  }

  /** Semantic alias for integrations that call their mailbox operation publish. */
  publish(input: MailInput | MailEnvelope): MailAppendResult {
    return this.append(input);
  }

  get(messageId: MailId): MailEnvelope | undefined {
    return this.messagesById.get(messageId);
  }

  getDelivery(messageId: MailId, recipient: AgentAddress): DeliveryReceipt | undefined {
    return this.deliveriesByMessage.get(messageId)?.get(recipient);
  }

  /** Return messages in append order, optionally filtered to one conversation. */
  list(options: { readonly threadId?: ThreadId } = {}): MailEnvelope[] {
    return this.appendOrder
      .map((id) => this.messagesById.get(id)!)
      .filter((message) => options.threadId === undefined || message.threadId === options.threadId);
  }

  thread(threadId: ThreadId): MailEnvelope[] {
    return this.list({ threadId });
  }

  /** Return one recipient's inbox, including the current delivery state. */
  inbox(recipient: AgentAddress, options: InboxOptions = {}): Array<{ envelope: MailEnvelope; delivery: DeliveryReceipt }> {
    const rows: Array<{ envelope: MailEnvelope; delivery: DeliveryReceipt }> = [];
    for (const id of this.appendOrder) {
      const envelope = this.messagesById.get(id)!;
      if (options.threadId !== undefined && envelope.threadId !== options.threadId) continue;
      const delivery = this.deliveriesByMessage.get(id)?.get(recipient);
      if (!delivery || (options.state !== undefined && delivery.state !== options.state)) continue;
      rows.push({ envelope, delivery });
    }
    return rows;
  }

  updateDelivery(messageId: MailId, recipient: AgentAddress, update: DeliveryUpdate): DeliveryReceipt {
    const envelope = this.messagesById.get(messageId);
    if (!envelope) throw new Error(`unknown mail message ${messageId}`);
    const deliveries = this.deliveriesByMessage.get(messageId)!;
    const current = deliveries.get(recipient);
    if (!current) throw new Error(`message ${messageId} has no recipient ${recipient}`);
    const next: DeliveryReceipt = {
      messageId,
      recipient,
      state: update.state,
      attempts: current.attempts + (update.state === "delivered" || update.state === "failed" ? 1 : 0),
      updatedAt: Date.now(),
      ...(update.error === undefined ? {} : { error: update.error }),
    };
    deliveries.set(recipient, next);
    this.emit({ kind: "delivery", envelope, delivery: next });
    return next;
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

  subscribe(recipient: AgentAddress, listener: MailListener): () => void {
    let listeners = this.listenersByRecipient.get(recipient);
    if (!listeners) {
      listeners = new Set();
      this.listenersByRecipient.set(recipient, listeners);
    }
    listeners.add(listener);
    return () => {
      listeners!.delete(listener);
      if (!listeners!.size) this.listenersByRecipient.delete(recipient);
    };
  }

  private deliveryList(messageId: MailId): DeliveryReceipt[] {
    return [...(this.deliveriesByMessage.get(messageId)?.values() ?? [])];
  }

  private emit(event: MailEvent): void {
    const recipients = event.kind === "appended" ? event.envelope.recipients : [event.delivery.recipient];
    for (const recipient of recipients) {
      for (const listener of this.listenersByRecipient.get(recipient) ?? []) listener(event);
    }
  }
}

export function createMail(input: MailInput): MailEnvelope {
  return normalizeEnvelope(input);
}

function normalizeEnvelope(input: MailInput | MailEnvelope, fallbackThreadId?: ThreadId): MailEnvelope {
  if (!input.sender?.trim()) throw new Error("mail sender is required");
  if (!input.recipients?.length) throw new Error("mail recipients are required");
  if (!input.body && input.body !== "") throw new Error("mail body is required");
  const recipients = [...new Set(input.recipients.map((recipient) => recipient.trim()).filter(Boolean))];
  if (!recipients.length) throw new Error("mail recipients are required");
  const id = input.id ?? newMailId();
  const threadId = input.threadId ?? fallbackThreadId ?? id;
  const references = [...new Set([...(input.references ?? []), ...(input.inReplyTo ? [input.inReplyTo] : [])])];
  const envelope: MailEnvelope = {
    id,
    threadId,
    kind: input.kind ?? (input.inReplyTo ? "reply" : "message"),
    sender: input.sender.trim(),
    recipients,
    ...(input.subject === undefined ? {} : { subject: input.subject }),
    body: input.body,
    contentType: input.contentType ?? "text/plain",
    createdAt: input.createdAt ?? Date.now(),
    ...(input.inReplyTo === undefined ? {} : { inReplyTo: input.inReplyTo }),
    references,
    attachments: (input.attachments ?? []).map((attachment) => ({ ...attachment })),
    metadata: cloneRecord(input.metadata ?? {}),
  };
  return freezeEnvelope(envelope);
}

function freezeEnvelope(envelope: MailEnvelope): MailEnvelope {
  Object.freeze(envelope.recipients);
  Object.freeze(envelope.references);
  Object.freeze(envelope.attachments);
  Object.freeze(envelope.metadata);
  return Object.freeze(envelope);
}

function fingerprint(envelope: MailEnvelope): string {
  return JSON.stringify(canonicalize(envelope));
}

function canonicalize(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(canonicalize);
  if (!value || typeof value !== "object") return value;
  return Object.fromEntries(Object.entries(value as Record<string, unknown>).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => [key, canonicalize(child)]));
}

function cloneRecord(record: Readonly<Record<string, unknown>>): Readonly<Record<string, unknown>> {
  try {
    return structuredClone(record);
  } catch {
    return Object.fromEntries(Object.entries(record).map(([key, value]) => [key, canonicalize(value)]));
  }
}

function newMailId(): MailId {
  return `mail_${globalThis.crypto?.randomUUID?.() ?? `${Date.now()}_${Math.random().toString(36).slice(2)}`}`;
}
