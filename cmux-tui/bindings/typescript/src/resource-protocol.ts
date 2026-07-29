import {
  CmuxAbortError,
  CmuxConnectionError,
  CmuxProtocolError,
  CmuxTimeoutError,
  ConfirmationRequiredError,
  MutationIndeterminateError,
  MutationTransportUncertainError,
  ResourceError,
  StreamError,
} from "./errors.js";
import {
  decimalString,
  paneId,
  streamId,
  type StreamId,
} from "./ids.js";
import type { Cursor, StreamEnd, StreamItem } from "./models.js";
import type { MutationOptions, RequestOptions } from "./options.js";
import type { Transport, Unsubscribe } from "./transport.js";
import type { Operation } from "./internal/operations.js";
import { operations } from "./internal/operations.js";

const PROTOCOL = "cmux.protocol/1";
const MAX_REQUEST_BYTES = 4 * 1024 * 1024;
export const MAX_STREAM_MESSAGES = 256;
export const MAX_STREAM_BYTES = 16 * 1024 * 1024;

interface Pending {
  resolve(value: unknown): void;
  reject(error: unknown): void;
  timer?: ReturnType<typeof setTimeout>;
  removeAbort?: () => void;
}

interface StreamState<Value> {
  readonly id: StreamId;
  readonly decode: (value: unknown) => Value;
  readonly cancelRoute: Readonly<{
    machine: string;
    session: string;
  }>;
  readonly values: Array<{
    readonly item: StreamItem<Value>;
    readonly bytes: number;
  }>;
  readonly waiters: Array<{
    resolve(value: IteratorResult<StreamItem<Value>>): void;
    reject(error: unknown): void;
    timer?: ReturnType<typeof setTimeout>;
    removeAbort?: () => void;
  }>;
  queuedBytes: number;
  end?: StreamEnd;
}

export interface ResourceProtocolOptions {
  readonly transport: Transport;
  readonly timeoutMs?: number;
  readonly localExecutor?: (
    operation: string,
    params: Readonly<Record<string, unknown>>,
  ) => unknown | Promise<unknown>;
  /** Tests can inject deterministic secure values. Production should omit it. */
  readonly randomHex128?: () => string;
}

export interface OperationResponse {
  readonly value: unknown;
  readonly idempotencyKey?: string;
}

/** Browser-safe resource envelope multiplexer. */
export class ResourceProtocol {
  private readonly transport: Transport;
  private readonly timeoutMs: number;
  private readonly localExecutor: ResourceProtocolOptions["localExecutor"];
  private readonly randomHex128: () => string;
  private readonly pending = new Map<string, Pending>();
  private readonly streams = new Map<StreamId, StreamState<unknown>>();
  private readonly unsubscribers: Unsubscribe[];
  private nextRequest = 0;
  private closed = false;
  private failure: Error | undefined;

  constructor(options: ResourceProtocolOptions) {
    this.transport = options.transport;
    this.timeoutMs = options.timeoutMs ?? 10_000;
    this.localExecutor = options.localExecutor;
    const randomHex128 = options.randomHex128 ?? secureRandomHex128;
    this.randomHex128 = () => {
      const value = randomHex128();
      if (!/^[0-9a-f]{32}$/.test(value)) {
        throw new TypeError("randomHex128 must return exactly 128 lowercase-hex bits");
      }
      return value;
    };
    this.unsubscribers = [
      this.transport.onMessage((json) => this.receive(json)),
      this.transport.onError((error) => this.fail(error)),
      this.transport.onClose(() => this.fail(new CmuxConnectionError("transport closed"))),
    ];
  }

  get isClosed(): boolean {
    return this.closed;
  }

  async request(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    options: RequestOptions & MutationOptions = {},
  ): Promise<OperationResponse> {
    if (operation.class === "local") {
      if (!this.localExecutor) {
        throw new Error(`${operation.name} requires an explicit localExecutor`);
      }
      return {
        value: await this.localExecutor(operation.name, Object.freeze({ ...params })),
      };
    }
    if (options.signal?.aborted) throw abortError();
    let idempotencyKey: string | undefined;
    if (operation.class === "mutation") {
      idempotencyKey = options.idempotencyKey ?? `ts-${this.randomHex128()}`;
      if (idempotencyKey.length < 1 || idempotencyKey.length > 128) {
        throw new TypeError("idempotencyKey must contain 1 to 128 characters");
      }
    } else if (options.idempotencyKey !== undefined) {
      throw new TypeError(`${operation.name} does not accept an idempotency key`);
    }
    let value: unknown;
    try {
      value = await this.sendRequest(
        operation.name,
        params,
        idempotencyKey,
        options.signal,
        options.timeoutMs,
      );
    } catch (error) {
      if (
        operation.class === "mutation"
        && idempotencyKey !== undefined
        && !(error instanceof ResourceError)
        && !(error instanceof CmuxProtocolError)
        && !(error instanceof TypeError)
      ) {
        throw new MutationTransportUncertainError(
          operation.name,
          idempotencyKey,
          error instanceof Error ? error : new Error(String(error)),
        );
      }
      throw error;
    }
    return { value, ...(idempotencyKey ? { idempotencyKey } : {}) };
  }

  async openStream<Value>(
    operation: Operation,
    params: Readonly<Record<string, unknown>>,
    decode: (value: unknown) => Value,
    options: RequestOptions = {},
  ): Promise<ResourceStream<Value>> {
    if (operation.class !== "stream_open") {
      throw new TypeError(`${operation.name} is not a stream operation`);
    }
    const id = streamId(`stream_${this.randomHex128()}`);
    if (
      typeof params.machine !== "string"
      || typeof params.session !== "string"
    ) {
      throw new CmuxProtocolError(
        `${operation.name} stream requires machine and session selectors`,
      );
    }
    const state: StreamState<Value> = {
      id,
      decode,
      cancelRoute: Object.freeze({
        machine: params.machine,
        session: params.session,
      }),
      values: [],
      waiters: [],
      queuedBytes: 0,
    };
    this.streams.set(id, state as StreamState<unknown>);
    try {
      const opened = await this.sendRequest(
        operation.name,
        { ...params, stream_id: id },
        undefined,
        options.signal,
        options.timeoutMs,
      );
      if (!isRecord(opened)) {
        throw new CmuxProtocolError(`${operation.name} result must be an object`);
      }
      const allowed = new Set(["stream_id", "cursor"]);
      const unknown = Object.keys(opened).find((key) => !allowed.has(key));
      if (unknown !== undefined) {
        throw new CmuxProtocolError(
          `${operation.name} result contains unknown field ${JSON.stringify(unknown)}`,
        );
      }
      if (opened.stream_id !== id) {
        throw new CmuxProtocolError(
          `${operation.name} returned stream ${String(opened.stream_id)} for ${id}`,
        );
      }
      if (Object.hasOwn(opened, "cursor")) decodeCursor(opened.cursor);
    } catch (error) {
      this.streams.delete(id);
      if (options.signal?.aborted && !this.closed) {
        void this.sendRequest(
          operations.streamCancel.name,
          { ...state.cancelRoute, stream: id },
          undefined,
          undefined,
        ).then(decodeEmptyResult).catch(() => {});
      }
      throw error;
    }
    const stream = new ResourceStream(this, state);
    if (options.signal) {
      if (options.signal.aborted) await stream.cancel();
      else {
        const cancel = () => void stream.cancel().catch(() => {});
        options.signal.addEventListener("abort", cancel, { once: true });
        stream.setAbortCleanup(() => options.signal?.removeEventListener("abort", cancel));
      }
    }
    return stream;
  }

  async cancelStream(id: StreamId, signal?: AbortSignal): Promise<void> {
    const state = this.streams.get(id);
    if (!state) return;
    decodeEmptyResult(
      await this.sendRequest(
        operations.streamCancel.name,
        { ...state.cancelRoute, stream: id },
        undefined,
        signal,
      ),
    );
    this.finishStream(
      state,
      { streamId: id, reason: "canceled" },
      true,
    );
  }

  forgetStream(id: StreamId): void {
    this.streams.delete(id);
  }

  close(): void {
    if (this.closed) return;
    this.fail(new CmuxConnectionError("resource client closed"));
    this.transport.close();
  }

  private sendRequest(
    operation: string,
    params: Readonly<Record<string, unknown>>,
    idempotencyKey?: string,
    signal?: AbortSignal,
    timeoutMs?: number,
  ): Promise<unknown> {
    if (this.closed) return Promise.reject(this.failure ?? new CmuxConnectionError("closed"));
    if (signal?.aborted) return Promise.reject(abortError());
    const effectiveTimeout = timeoutMs ?? this.timeoutMs;
    if (
      !Number.isFinite(effectiveTimeout)
      || effectiveTimeout < 0
      || effectiveTimeout > 0x7fff_ffff
    ) {
      return Promise.reject(
        new TypeError("timeoutMs must be between 0 and 2147483647"),
      );
    }
    const requestId = `ts-${++this.nextRequest}`;
    const envelope = {
      protocol: PROTOCOL,
      type: "request",
      id: requestId,
      operation,
      params,
      ...(idempotencyKey !== undefined
        ? { idempotency_key: idempotencyKey }
        : {}),
    };
    let json: string;
    try {
      json = JSON.stringify(envelope);
    } catch (error) {
      return Promise.reject(
        new CmuxProtocolError(`cannot encode ${operation}: ${String(error)}`),
      );
    }
    if (new TextEncoder().encode(json).byteLength > MAX_REQUEST_BYTES) {
      return Promise.reject(
        new CmuxProtocolError(
          `request exceeds ${MAX_REQUEST_BYTES}-byte resource-protocol limit`,
        ),
      );
    }
    return new Promise<unknown>((resolve, reject) => {
      const pending: Pending = { resolve, reject };
      if (effectiveTimeout > 0) {
        pending.timer = setTimeout(() => {
          this.pending.delete(requestId);
          pending.removeAbort?.();
          reject(new CmuxTimeoutError(`${operation} timed out`));
        }, effectiveTimeout);
      }
      if (signal) {
        const abort = () => {
          this.pending.delete(requestId);
          if (pending.timer) clearTimeout(pending.timer);
          reject(abortError());
        };
        signal.addEventListener("abort", abort, { once: true });
        pending.removeAbort = () => signal.removeEventListener("abort", abort);
      }
      this.pending.set(requestId, pending);
      try {
        this.transport.send(json);
      } catch (error) {
        this.pending.delete(requestId);
        this.finishPending(pending);
        reject(error);
      }
    });
  }

  private receive(json: string): void {
    let value: unknown;
    try {
      value = JSON.parse(json);
    } catch (error) {
      this.fail(new CmuxProtocolError(`invalid JSON from server: ${String(error)}`));
      return;
    }
    if (!isRecord(value) || value.protocol !== PROTOCOL || typeof value.type !== "string") {
      this.fail(new CmuxProtocolError("invalid resource envelope"));
      return;
    }
    if (value.type === "response") {
      if (typeof value.id !== "string") {
        this.fail(new CmuxProtocolError("response id must be a string"));
        return;
      }
      const pending = this.pending.get(value.id);
      if (!pending) return;
      this.pending.delete(value.id);
      this.finishPending(pending);
      if (value.ok === true && "result" in value && !("error" in value)) {
        pending.resolve(value.result);
      } else if (value.ok === false && "error" in value && !("result" in value)) {
        try {
          pending.reject(decodeResourceError(value.error));
        } catch (error) {
          pending.reject(error);
        }
      } else {
        pending.reject(new CmuxProtocolError("invalid response result/error fields"));
      }
      return;
    }
    if (value.type === "stream_item" || value.type === "stream_end") {
      let id: StreamId;
      try {
        id = streamId(String(value.stream_id));
      } catch (error) {
        this.fail(new CmuxProtocolError(`invalid stream ID: ${String(error)}`));
        return;
      }
      const state = this.streams.get(id);
      if (!state) return;
      if (value.type === "stream_item") {
        if (state.end) return;
        try {
          const item: StreamItem<unknown> = Object.freeze({
            streamId: id,
            sequence: decimalString(requireString(value.sequence, "sequence")),
            ...("cursor" in value && value.cursor !== undefined
              ? { cursor: decodeCursor(value.cursor) }
              : {}),
            value: state.decode(value.item),
          });
          const waiter = state.waiters.shift();
          if (waiter) {
            finishStreamWaiter(waiter);
            waiter.resolve({ done: false, value: item });
          }
          else {
            const bytes = new TextEncoder().encode(json).byteLength;
            if (
              state.values.length >= MAX_STREAM_MESSAGES
              || bytes > MAX_STREAM_BYTES - state.queuedBytes
            ) {
              this.finishStream(
                state,
                {
                  streamId: id,
                  reason: "gap",
                  recovery: "reopen the stream to obtain a fresh snapshot",
                },
                true,
              );
              this.cancelStreamBestEffort(state);
              return;
            }
            state.values.push({ item, bytes });
            state.queuedBytes += bytes;
          }
        } catch (error) {
          this.finishStream(state, {
            streamId: id,
            reason: "error",
            error: error instanceof Error ? error : new CmuxProtocolError(String(error)),
          });
        }
        return;
      }
      try {
        const reason = value.reason;
        if (!["completed", "canceled", "closed", "gap", "error"].includes(String(reason))) {
          throw new CmuxProtocolError("invalid stream end reason");
        }
        this.finishStream(state, {
          streamId: id,
          reason: reason as StreamEnd["reason"],
          ...("cursor" in value && value.cursor !== undefined
            ? { cursor: decodeCursor(value.cursor) }
            : {}),
          ...("error" in value && value.error !== undefined
            ? { error: decodeResourceError(value.error) }
            : {}),
          ...(typeof value.recovery === "string" ? { recovery: value.recovery } : {}),
        });
      } catch (error) {
        this.finishStream(state, {
          streamId: id,
          reason: "error",
          error: error instanceof Error ? error : new CmuxProtocolError(String(error)),
        });
      }
      return;
    }
    this.fail(new CmuxProtocolError(`unknown envelope type ${value.type}`));
  }

  private finishStream(
    state: StreamState<unknown>,
    end: StreamEnd,
    purge = false,
  ): void {
    if (state.end) {
      if (purge) {
        state.values.length = 0;
        state.queuedBytes = 0;
      }
      return;
    }
    state.end = Object.freeze(end);
    this.streams.delete(state.id);
    if (purge) {
      state.values.length = 0;
      state.queuedBytes = 0;
    }
    for (const waiter of state.waiters.splice(0)) {
      finishStreamWaiter(waiter);
      if (end.reason === "gap" || end.reason === "error") {
        waiter.reject(
          end.error instanceof ResourceError
            ? new StreamError(end.reason, {
              error: end.error,
              recovery: end.recovery,
            })
            : end.error ?? new StreamError(end.reason, { recovery: end.recovery }),
        );
      } else {
        waiter.resolve({ done: true, value: undefined });
      }
    }
  }

  private cancelStreamBestEffort(state: StreamState<unknown>): void {
    void this.sendRequest(
      operations.streamCancel.name,
      { ...state.cancelRoute, stream: state.id },
      undefined,
      undefined,
    ).then(decodeEmptyResult).catch(() => {});
  }

  private finishPending(pending: Pending): void {
    if (pending.timer) clearTimeout(pending.timer);
    pending.removeAbort?.();
  }

  private fail(error: Error): void {
    if (this.closed) return;
    this.closed = true;
    this.failure = error;
    for (const pending of this.pending.values()) {
      this.finishPending(pending);
      pending.reject(error);
    }
    this.pending.clear();
    for (const state of this.streams.values()) {
      this.finishStream(state, { streamId: state.id, reason: "error", error });
    }
    this.streams.clear();
    for (const unsubscribe of this.unsubscribers.splice(0)) unsubscribe();
  }
}

export class ResourceStream<Value>
implements AsyncIterable<StreamItem<Value>>, AsyncIterator<StreamItem<Value>> {
  private abortCleanup: (() => void) | undefined;
  private canceling: Promise<void> | undefined;

  constructor(
    private readonly protocol: ResourceProtocol,
    private readonly state: StreamState<Value>,
  ) {}

  get id(): StreamId {
    return this.state.id;
  }

  get end(): StreamEnd | undefined {
    return this.state.end;
  }

  [Symbol.asyncIterator](): AsyncIterator<StreamItem<Value>> {
    return this;
  }

  next(
    options: RequestOptions = {},
  ): Promise<IteratorResult<StreamItem<Value>>> {
    const queued = this.state.values.shift();
    if (queued) {
      this.state.queuedBytes -= queued.bytes;
      return Promise.resolve({ done: false, value: queued.item });
    }
    if (this.state.end) {
      const end = this.state.end;
      if (end.reason === "gap" || end.reason === "error") {
        return Promise.reject(
          end.error instanceof ResourceError
            ? new StreamError(end.reason, {
              error: end.error,
              recovery: end.recovery,
            })
            : end.error ?? new StreamError(end.reason, { recovery: end.recovery }),
        );
      }
      return Promise.resolve({ done: true, value: undefined });
    }
    if (options.signal?.aborted) return Promise.reject(abortError());
    const timeoutMs = options.timeoutMs;
    if (
      timeoutMs !== undefined
      && (
        !Number.isFinite(timeoutMs)
        || timeoutMs < 0
        || timeoutMs > 0x7fff_ffff
      )
    ) {
      return Promise.reject(
        new TypeError("timeoutMs must be between 0 and 2147483647"),
      );
    }
    return new Promise((resolve, reject) => {
      const waiter: StreamState<Value>["waiters"][number] = {
        resolve,
        reject,
      };
      const remove = () => {
        const index = this.state.waiters.indexOf(waiter);
        if (index >= 0) this.state.waiters.splice(index, 1);
        finishStreamWaiter(waiter);
      };
      if (timeoutMs !== undefined && timeoutMs > 0) {
        waiter.timer = setTimeout(() => {
          remove();
          reject(new CmuxTimeoutError("stream receive timed out"));
        }, timeoutMs);
      }
      if (options.signal) {
        const abort = () => {
          remove();
          reject(abortError());
        };
        options.signal.addEventListener("abort", abort, { once: true });
        waiter.removeAbort = () =>
          options.signal?.removeEventListener("abort", abort);
      }
      this.state.waiters.push(waiter);
    });
  }

  async cancel(signal?: AbortSignal): Promise<void> {
    if (this.state.end) return;
    if (!this.canceling) {
      this.canceling = this.protocol.cancelStream(this.id, signal).finally(() => {
        this.abortCleanup?.();
        this.abortCleanup = undefined;
      });
    }
    await this.canceling;
  }

  async return(): Promise<IteratorResult<StreamItem<Value>>> {
    await this.cancel();
    return { done: true, value: undefined };
  }

  setAbortCleanup(cleanup: () => void): void {
    this.abortCleanup = cleanup;
  }
}

function secureRandomHex128(): string {
  const cryptoObject = globalThis.crypto;
  if (!cryptoObject?.getRandomValues) {
    throw new Error("secure random generation is unavailable");
  }
  const bytes = cryptoObject.getRandomValues(new Uint8Array(16));
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}

function abortError(): CmuxAbortError {
  return new CmuxAbortError("operation aborted");
}

function finishStreamWaiter(
  waiter: {
    timer?: ReturnType<typeof setTimeout>;
    removeAbort?: () => void;
  },
): void {
  if (waiter.timer) clearTimeout(waiter.timer);
  waiter.removeAbort?.();
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function decodeEmptyResult(value: unknown): void {
  if (!isRecord(value) || Object.keys(value).length !== 0) {
    throw new CmuxProtocolError("empty result must be an object with no fields");
  }
}

function requireString(value: unknown, name: string): string {
  if (typeof value !== "string") throw new CmuxProtocolError(`${name} must be a string`);
  return value;
}

function decodeCursor(value: unknown): Cursor {
  if (!isRecord(value)) throw new CmuxProtocolError("cursor must be an object");
  if (
    Object.keys(value).length !== 2
    || !Object.hasOwn(value, "generation")
    || !Object.hasOwn(value, "revision")
  ) {
    throw new CmuxProtocolError("cursor must contain only generation and revision");
  }
  const generation = requireString(value.generation, "cursor.generation");
  if (generation.length < 1 || generation.length > 128) {
    throw new CmuxProtocolError(
      "cursor.generation must contain 1 to 128 characters",
    );
  }
  return Object.freeze({
    generation,
    revision: decimalString(requireString(value.revision, "cursor.revision")),
  });
}

function decodeResourceError(value: unknown): ResourceError {
  if (
    !isRecord(value)
    || typeof value.code !== "string"
    || typeof value.message !== "string"
    || typeof value.retryable !== "boolean"
  ) {
    throw new CmuxProtocolError("invalid structured error");
  }
  if (value.code === "confirmation.required") {
    const details = value.details;
    if (
      value.retryable
      || !isRecord(details)
      || Object.keys(details).length !== 3
      || typeof details.confirmation_token !== "string"
      || details.confirmation_token.length < 1
      || details.confirmation_token.length > 128
      || typeof details.revision !== "string"
      || !Array.isArray(details.closes_panes)
      || details.closes_panes.length === 0
      || details.closes_panes.some((item) => typeof item !== "string")
    ) {
      throw new CmuxProtocolError("confirmation.required has invalid details");
    }
    try {
      return new ConfirmationRequiredError(value.message, {
        confirmation_token: details.confirmation_token,
        revision: decimalString(details.revision),
        closes_panes: Object.freeze(
          details.closes_panes.map((item) => paneId(item as string)),
        ),
      });
    } catch {
      throw new CmuxProtocolError("confirmation.required has invalid details");
    }
  }
  if (value.code === "mutation.indeterminate") {
    const details = value.details;
    if (
      value.retryable
      || !isRecord(details)
      || Object.keys(details).length !== 3
      || typeof details.idempotency_key !== "string"
      || typeof details.operation !== "string"
      || details.recovery !== "inspect_state_then_retry_with_new_key"
    ) {
      throw new CmuxProtocolError("mutation.indeterminate has invalid details");
    }
    return new MutationIndeterminateError(value.message, {
      idempotency_key: details.idempotency_key,
      operation: details.operation,
      recovery: details.recovery,
    });
  }
  return new ResourceError(value.code, value.message, value.details, value.retryable);
}
