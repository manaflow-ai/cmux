import {
  CmuxAbortError,
  CmuxAuthenticationRejectedError,
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
import {
  hasUtf8ByteLength,
  isValidIdempotencyKey,
} from "./internal/text.js";

const PROTOCOL = "cmux.protocol/2";
const MAX_REQUEST_BYTES = 4 * 1024 * 1024;
const DEFAULT_REQUEST_TIMEOUT_MS = 10_000;
const STREAM_OPEN_CLEANUP_TIMEOUT_MS = 1_000;
const REQUEST_CLEANUP_TIMEOUT_MS = 1_000;
const MAX_TIMEOUT_MS = 0x7fff_ffff;
const TERMINAL_WAIT_CAPACITY = 8;
// The server checks canceled/disconnected wait workers in 100 ms slices. Keep
// the local lease through one final slice unless its response proves it exited.
const TERMINAL_WAIT_RELEASE_GRACE_MS = 100;
const MAX_TERMINAL_WAIT_TIMEOUT_MS =
  MAX_TIMEOUT_MS - TERMINAL_WAIT_RELEASE_GRACE_MS;
export const MAX_STREAM_MESSAGES = 256;
export const MAX_STREAM_BYTES = 16 * 1024 * 1024;

interface Pending {
  resolve(value: unknown): void;
  reject(error: unknown): void;
  onResourceError?: () => void;
  validateAbandonedResult?: (value: unknown) => unknown;
  timer?: ReturnType<typeof setTimeout>;
  readonly dispatchDeadline?: number;
  removeAbort?: () => void;
  cancelUndispatched?: Unsubscribe;
  abandonment?: RequestAbandonment;
}

interface RequestAbandonment {
  readonly originalError: CmuxAbortError | CmuxTimeoutError;
  readonly targetResponse: Promise<Error | undefined>;
  readonly resolveTargetResponse: (error: Error | undefined) => void;
  readonly cleanupBarrier: Promise<void>;
  readonly resolveCleanupBarrier: () => void;
  targetResponseObserved: boolean;
  cleanupStarted: boolean;
  cleanupFinished: boolean;
}

interface TerminalWaitLease {
  readonly durationMs: number;
  expiresAt?: number;
  timer?: ReturnType<typeof setTimeout>;
}

interface StreamCancellationConfirmation {
  readonly promise: Promise<StreamEnd>;
  readonly resolve: (end: StreamEnd) => void;
  readonly reject: (error: unknown) => void;
  responseConfirmed: boolean;
  end?: StreamEnd;
  settled: boolean;
}

interface StreamState<Value> {
  readonly id: StreamId;
  attachmentLease?: string;
  readonly decode: (value: unknown) => Value;
  readonly validate?: (value: unknown, cursor: Cursor | undefined) => void;
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
  openDispatched: boolean;
  openAcknowledged: boolean;
  openRejected: boolean;
  openSendFailed: boolean;
  openSendError?: unknown;
  cleanupStarted: boolean;
  cancellation?: StreamCancellationConfirmation;
  abortCleanup?: () => void;
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
  private readonly terminalWaitLeases = new Map<string, TerminalWaitLease>();
  private readonly requestCleanups = new Set<Promise<void>>();
  private readonly streams = new Map<StreamId, StreamState<unknown>>();
  private readonly unsubscribers: Unsubscribe[];
  private nextRequest = 0;
  private closed = false;
  private failure: Error | undefined;
  private failureAttemptCleanup = true;
  private failureStreams: StreamState<unknown>[] | undefined;
  private failureFinalized = false;
  private failureFinalizeScheduled = false;
  private activeTransportSends = 0;
  private transportCloseStarted = false;

  constructor(options: ResourceProtocolOptions) {
    this.transport = options.transport;
    this.timeoutMs = options.timeoutMs ?? DEFAULT_REQUEST_TIMEOUT_MS;
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
    validateAbandonedResult?: (value: unknown) => unknown,
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
      if (!isValidIdempotencyKey(idempotencyKey)) {
        throw new TypeError(
          "idempotencyKey must be valid Unicode, contain 1 to 128 UTF-8 bytes and a non-whitespace character, and contain no control characters",
        );
      }
    } else if (options.idempotencyKey !== undefined) {
      throw new TypeError(`${operation.name} does not accept an idempotency key`);
    }
    let value: unknown;
    let dispatchStarted = false;
    try {
      value = await this.sendRequest(
        operation.name,
        params,
        idempotencyKey,
        options.signal,
        options.timeoutMs,
        undefined,
        undefined,
        undefined,
        validateAbandonedResult,
        () => {
          dispatchStarted = true;
        },
      );
    } catch (error) {
      if (
        operation.class === "mutation"
        && idempotencyKey !== undefined
        && !(error instanceof ResourceError)
        && !(error instanceof CmuxAuthenticationRejectedError)
        && !(error instanceof CmuxProtocolError)
        && !(error instanceof TypeError)
        && dispatchStarted
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
    validate?: (value: Value, cursor: Cursor | undefined) => void,
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
      validate: validate === undefined
        ? undefined
        : (value, cursor) => validate(value as Value, cursor),
      cancelRoute: Object.freeze({
        machine: params.machine,
        session: params.session,
      }),
      values: [],
      waiters: [],
      queuedBytes: 0,
      openDispatched: false,
      openAcknowledged: false,
      openRejected: false,
      openSendFailed: false,
      cleanupStarted: false,
    };
    this.streams.set(id, state as StreamState<unknown>);
    try {
      const opened = await this.sendRequest(
        operation.name,
        { ...params, stream_id: id },
        undefined,
        options.signal,
        options.timeoutMs,
        () => {
          state.openDispatched = true;
        },
        (error) => {
          state.openSendFailed = true;
          state.openSendError = error;
          this.fail(new CmuxConnectionError(
            `${operation.name} transport send failed: ${String(error)}`,
          ), false);
        },
        () => {
          state.openRejected = true;
        },
      );
      if (state.openSendFailed) throw state.openSendError;
      if (!isRecord(opened)) {
        throw new CmuxProtocolError(`${operation.name} result must be an object`);
      }
      const isViewAttachment = operation.name === operations.terminalAttach.name
        || operation.name === operations.browserAttach.name;
      const allowed = new Set([
        "stream_id",
        "cursor",
        ...(isViewAttachment ? ["attachment_lease"] : []),
      ]);
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
      if (isViewAttachment) {
        if (
          typeof opened.attachment_lease !== "string"
          || !hasUtf8ByteLength(opened.attachment_lease, 1, 128)
        ) {
          throw new CmuxProtocolError(
            `${operation.name} result requires a 1 to 128 byte attachment_lease`,
          );
        }
        state.attachmentLease = opened.attachment_lease;
      }
      if (Object.hasOwn(opened, "cursor")) decodeCursor(opened.cursor);
      if (this.closed) {
        throw this.failure ?? new CmuxConnectionError("resource client closed");
      }
      state.openAcknowledged = true;
    } catch (error) {
      this.streams.delete(id);
      const openError = state.openSendFailed ? state.openSendError : error;
      if (!state.openSendFailed && !state.openRejected && !this.closed && state.openDispatched) {
        await this.cleanupFailedStreamOpen(state, operation.name);
      }
      throw openError;
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
    if (signal?.aborted) throw abortError();
    if (!this.beginStreamRouteCleanup(state)) return;
    const timeoutMs = this.timeoutMs > 0
      ? this.timeoutMs
      : STREAM_OPEN_CLEANUP_TIMEOUT_MS;
    const deadline = Date.now() + timeoutMs;
    const confirmation = createStreamCancellationConfirmation();
    state.cancellation = confirmation;
    const confirmed = waitUntilDeadline(
      confirmation.promise,
      deadline,
      signal,
      "stream cancellation timed out",
    );
    void this.sendRequest(
      operations.streamCancel.name,
      { ...state.cancelRoute, stream: id },
      undefined,
      signal,
      0,
    ).then(
      (result) => {
        try {
          decodeEmptyResult(result);
          confirmation.responseConfirmed = true;
          this.completeStreamCancellation(state);
        } catch (error) {
          this.rejectStreamCancellation(state, error);
        }
      },
      (error) => this.rejectStreamCancellation(state, error),
    );
    try {
      await confirmed;
    } catch (error) {
      this.rejectStreamCancellation(state, error);
      state.values.length = 0;
      state.queuedBytes = 0;
      this.fail(new CmuxConnectionError(
        `stream cancellation was not confirmed: ${String(error)}`,
      ));
      throw error;
    }
  }

  forgetStream(id: StreamId): void {
    this.streams.delete(id);
  }

  close(): void {
    this.fail(new CmuxConnectionError("resource client closed"));
  }

  private sendRequest(
    operation: string,
    params: Readonly<Record<string, unknown>>,
    idempotencyKey?: string,
    signal?: AbortSignal,
    timeoutMs?: number,
    onDispatched?: () => void,
    onSendError?: (error: unknown) => void,
    onResourceError?: () => void,
    validateAbandonedResult?: (value: unknown) => unknown,
    onDispatchStarted?: () => void,
  ): Promise<unknown> {
    if (this.requestCleanups.size === 0) {
      return this.sendRequestNow(
        operation,
        params,
        idempotencyKey,
        signal,
        timeoutMs,
        onDispatched,
        onSendError,
        onResourceError,
        validateAbandonedResult,
        onDispatchStarted,
      );
    }
    return this.sendRequestAfterCleanup(
      operation,
      params,
      idempotencyKey,
      signal,
      timeoutMs,
      onDispatched,
      onSendError,
      onResourceError,
      validateAbandonedResult,
      onDispatchStarted,
    );
  }

  private async sendRequestAfterCleanup(
    operation: string,
    params: Readonly<Record<string, unknown>>,
    idempotencyKey?: string,
    signal?: AbortSignal,
    timeoutMs?: number,
    onDispatched?: () => void,
    onSendError?: (error: unknown) => void,
    onResourceError?: () => void,
    validateAbandonedResult?: (value: unknown) => unknown,
    onDispatchStarted?: () => void,
  ): Promise<unknown> {
    if (this.closed) {
      throw this.failure ?? new CmuxConnectionError("closed");
    }
    if (signal?.aborted) throw abortError();
    const effectiveTimeout = timeoutMs ?? this.timeoutMs;
    validateTimeout(effectiveTimeout);
    const deadline = effectiveTimeout > 0
      ? Date.now() + effectiveTimeout
      : undefined;
    while (this.requestCleanups.size > 0) {
      await waitUntilDeadline(
        Promise.all([...this.requestCleanups]),
        deadline,
        signal,
        `${operation} timed out before dispatch`,
      );
    }
    const remaining = deadline === undefined
      ? 0
      : deadline - Date.now();
    if (deadline !== undefined && remaining <= 0) {
      throw new CmuxTimeoutError(`${operation} timed out before dispatch`);
    }
    return this.sendRequestNow(
      operation,
      params,
      idempotencyKey,
      signal,
      remaining,
      onDispatched,
      onSendError,
      onResourceError,
      validateAbandonedResult,
      onDispatchStarted,
    );
  }

  private sendRequestNow(
    operation: string,
    params: Readonly<Record<string, unknown>>,
    idempotencyKey?: string,
    signal?: AbortSignal,
    timeoutMs?: number,
    onDispatched?: () => void,
    onSendError?: (error: unknown) => void,
    onResourceError?: () => void,
    validateAbandonedResult?: (value: unknown) => unknown,
    onDispatchStarted?: () => void,
  ): Promise<unknown> {
    if (this.closed) return Promise.reject(this.failure ?? new CmuxConnectionError("closed"));
    if (signal?.aborted) return Promise.reject(abortError());
    const effectiveTimeout = timeoutMs ?? this.timeoutMs;
    try {
      validateTimeout(effectiveTimeout);
    } catch (error) {
      return Promise.reject(error);
    }
    const requestId = `ts-${++this.nextRequest}`;
    const terminalWaitTimeout = terminalWaitServerTimeout(
      operation,
      params,
      effectiveTimeout,
    );
    const requestParams = terminalWaitTimeout === undefined
      ? params
      : {
        ...params,
        timeout_ms: terminalWaitTimeout.toString(),
      };
    const envelope = {
      protocol: PROTOCOL,
      type: "request",
      id: requestId,
      operation,
      params: requestParams,
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
    if (
      terminalWaitTimeout !== undefined
      && !this.reserveTerminalWait(requestId, Number(terminalWaitTimeout))
    ) {
      return Promise.reject(
        new CmuxProtocolError(
          `terminal wait capacity is ${TERMINAL_WAIT_CAPACITY}; retry after an active wait reaches its server deadline`,
        ),
      );
    }
    return new Promise<unknown>((resolve, reject) => {
      const pending: Pending = {
        resolve,
        reject,
        onResourceError,
        validateAbandonedResult,
        ...(effectiveTimeout > 0
          ? { dispatchDeadline: monotonicNow() + effectiveTimeout }
          : {}),
      };
      let dispatchStarted = false;
      let dispatchComplete = false;
      const abandon = (
        error: CmuxAbortError | CmuxTimeoutError,
      ) => {
        if (this.pending.get(requestId) !== pending) return;
        if (isCancelableTerminalWait(operation) && dispatchStarted) {
          this.beginRequestAbandonment(requestId, pending, error);
          if (dispatchComplete) {
            this.startRequestCleanup(requestId, pending);
          }
          return;
        }
        this.pending.delete(requestId);
        this.finishPending(pending);
        this.releaseTerminalWait(requestId);
        reject(error);
      };
      if (effectiveTimeout > 0) {
        pending.timer = setTimeout(() => {
          abandon(new CmuxTimeoutError(`${operation} timed out`));
        }, effectiveTimeout);
      }
      if (signal) {
        const abort = () => {
          abandon(abortError());
        };
        signal.addEventListener("abort", abort, { once: true });
        pending.removeAbort = () => signal.removeEventListener("abort", abort);
      }
      this.pending.set(requestId, pending);
      if (signal?.aborted) {
        this.pending.delete(requestId);
        this.finishPending(pending);
        this.releaseTerminalWait(requestId);
        reject(abortError());
        return;
      }
      try {
        this.activeTransportSends += 1;
        try {
          if (
            this.transport.supportsDispatchGuard === true
            && this.transport.sendCancellable
          ) {
            const cancelUndispatched = this.transport.sendCancellable(
              json,
              () => {
                if (dispatchStarted) return;
                dispatchStarted = true;
                this.startTerminalWaitLease(requestId);
                const release = pending.cancelUndispatched;
                pending.cancelUndispatched = undefined;
                release?.();
                onDispatchStarted?.();
                onDispatched?.();
              },
              () => {
                if (this.pending.get(requestId) !== pending) return false;
                if (signal?.aborted) {
                  abandon(abortError());
                  return false;
                }
                if (
                  pending.dispatchDeadline !== undefined
                  && monotonicNow() >= pending.dispatchDeadline
                ) {
                  abandon(new CmuxTimeoutError(`${operation} timed out`));
                  return false;
                }
                return true;
              },
            );
            if (
              !dispatchStarted
              && this.pending.get(requestId) === pending
            ) {
              pending.cancelUndispatched = cancelUndispatched;
            } else {
              cancelUndispatched();
            }
          } else {
            dispatchStarted = true;
            this.startTerminalWaitLease(requestId);
            onDispatchStarted?.();
            this.transport.send(json);
            onDispatched?.();
          }
          dispatchComplete = true;
        } finally {
          this.activeTransportSends -= 1;
        }
        if (pending.abandonment) {
          this.startRequestCleanup(requestId, pending);
        }
      } catch (error) {
        this.pending.delete(requestId);
        this.finishPending(pending);
        this.releaseTerminalWait(requestId);
        onSendError?.(error);
        if (!onSendError) {
          this.fail(new CmuxConnectionError(
            `${operation} transport send failed: ${String(error)}`,
          ), false);
        }
        reject(pending.abandonment?.originalError ?? error);
        this.finishRequestCleanup(pending);
      }
    });
  }

  private receive(json: string): void {
    if (this.closed) return;
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
      this.releaseTerminalWait(value.id);
      const pending = this.pending.get(value.id);
      let decoded: DecodedResponse;
      try {
        decoded = decodeResponseEnvelope(value);
      } catch (error) {
        const failure = error instanceof Error
          ? error
          : new CmuxProtocolError(String(error));
        if (pending) {
          this.pending.delete(value.id);
          this.finishPending(pending);
          if (pending.abandonment) {
            pending.abandonment.targetResponseObserved = true;
            pending.abandonment.resolveTargetResponse(failure);
          } else {
            pending.reject(failure);
          }
        }
        this.fail(failure);
        return;
      }
      if (!pending) return;
      this.pending.delete(value.id);
      this.finishPending(pending);
      if (pending.abandonment) {
        pending.abandonment.targetResponseObserved = true;
        let validationError: Error | undefined;
        if (decoded.ok && pending.validateAbandonedResult) {
          try {
            pending.validateAbandonedResult(decoded.result);
          } catch (error) {
            validationError = error instanceof Error
              ? error
              : new CmuxProtocolError(String(error));
          }
        }
        pending.abandonment.resolveTargetResponse(validationError);
        return;
      }
      if (decoded.ok) pending.resolve(decoded.result);
      else {
        pending.onResourceError?.();
        pending.reject(decoded.error);
      }
      return;
    }
    if (value.type === "stream_item" || value.type === "stream_end") {
      if (typeof value.stream_id !== "string") {
        this.fail(new CmuxProtocolError("stream_id must be a string"));
        return;
      }
      let id: StreamId;
      try {
        id = streamId(value.stream_id);
      } catch (error) {
        this.fail(new CmuxProtocolError(`invalid stream ID: ${String(error)}`));
        return;
      }
      const state = this.streams.get(id);
      if (!state) return;
      if (value.type === "stream_item") {
        if (state.end) return;
        try {
          const item = decodeStreamItemEnvelope(value, id, state.decode, state.validate);
          if (state.cancellation?.end) {
            throw new CmuxProtocolError(
              "stream item received after end envelope",
            );
          }
          if (state.cancellation) return;
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
          const failure = error instanceof Error
            ? error
            : new CmuxProtocolError(String(error));
          if (state.cancellation) {
            this.rejectStreamCancellation(state, failure);
          } else {
            this.fail(failure);
          }
        }
        return;
      }
      try {
        const end = decodeStreamEndEnvelope(value, id);
        if (state.cancellation) {
          if (state.cancellation.end) {
            throw new CmuxProtocolError(
              "stream cancellation received more than one end envelope",
            );
          }
          if (end.reason !== "canceled") {
            throw new CmuxProtocolError(
              `stream cancellation ended with ${end.reason}, expected canceled`,
            );
          }
          state.cancellation.end = end;
          this.completeStreamCancellation(state);
        } else {
          this.finishStream(state, end);
        }
      } catch (error) {
        const failure = error instanceof Error
          ? error
          : new CmuxProtocolError(String(error));
        if (state.cancellation) {
          this.rejectStreamCancellation(state, failure);
        } else {
          this.fail(failure);
        }
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
    state.abortCleanup?.();
    state.abortCleanup = undefined;
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
    if (!this.beginStreamRouteCleanup(state)) return;
    if (this.closed) {
      this.sendStreamCancelUntracked(state);
      return;
    }
    void this.sendRequest(
      operations.streamCancel.name,
      { ...state.cancelRoute, stream: state.id },
      undefined,
      undefined,
      STREAM_OPEN_CLEANUP_TIMEOUT_MS,
    ).then(decodeEmptyResult).catch((error) => {
      this.fail(new CmuxConnectionError(
        `stream cancellation was not confirmed: ${String(error)}`,
      ));
    });
  }

  private async cleanupFailedStreamOpen(
    state: StreamState<unknown>,
    operation: string,
  ): Promise<void> {
    if (!this.beginStreamRouteCleanup(state)) return;
    try {
      decodeEmptyResult(await this.sendRequest(
        operations.streamCancel.name,
        { ...state.cancelRoute, stream: state.id },
        undefined,
        undefined,
        STREAM_OPEN_CLEANUP_TIMEOUT_MS,
        undefined,
        (error) => {
          this.fail(new CmuxConnectionError(
            `${operation} failed-open cleanup was not confirmed: ${String(error)}`,
          ), false);
        },
      ));
    } catch (error) {
      this.fail(new CmuxConnectionError(
        `${operation} failed-open cleanup was not confirmed: ${String(error)}`,
      ));
    }
  }

  private beginStreamRouteCleanup(state: StreamState<unknown>): boolean {
    if (state.cleanupStarted) return false;
    state.cleanupStarted = true;
    return true;
  }

  private completeStreamCancellation(state: StreamState<unknown>): void {
    const confirmation = state.cancellation;
    if (
      !confirmation
      || confirmation.settled
      || !confirmation.responseConfirmed
      || !confirmation.end
    ) {
      return;
    }
    confirmation.settled = true;
    const end = confirmation.end;
    state.cancellation = undefined;
    this.finishStream(state, end, true);
    confirmation.resolve(end);
  }

  private rejectStreamCancellation(
    state: StreamState<unknown>,
    error: unknown,
  ): void {
    const confirmation = state.cancellation;
    if (!confirmation || confirmation.settled) return;
    confirmation.settled = true;
    confirmation.reject(error);
  }

  private sendStreamCancelUntracked(state: StreamState<unknown>): void {
    // A transport error closes the protocol before the rejected open resumes.
    // The connection may still accept one last write, so attempt cancellation
    // without registering a response that can no longer be observed.
    let json: string;
    try {
      json = JSON.stringify({
        protocol: PROTOCOL,
        type: "request",
        id: `ts-${++this.nextRequest}`,
        operation: operations.streamCancel.name,
        params: { ...state.cancelRoute, stream: state.id },
      });
    } catch {
      return;
    }
    if (new TextEncoder().encode(json).byteLength > MAX_REQUEST_BYTES) return;
    try {
      this.transport.send(json);
    } catch {
      // Preserve the stream-open failure that initiated cleanup.
    }
  }

  private beginRequestAbandonment(
    requestId: string,
    pending: Pending,
    originalError: CmuxAbortError | CmuxTimeoutError,
  ): void {
    if (pending.abandonment) return;
    this.finishPending(pending);
    const abandonment = createRequestAbandonment(originalError);
    pending.abandonment = abandonment;
    this.requestCleanups.add(abandonment.cleanupBarrier);
    if (this.pending.get(requestId) !== pending) {
      abandonment.targetResponseObserved = true;
      abandonment.resolveTargetResponse(undefined);
    }
  }

  private startRequestCleanup(requestId: string, pending: Pending): void {
    const abandonment = pending.abandonment;
    if (
      !abandonment
      || abandonment.cleanupStarted
      || abandonment.cleanupFinished
    ) {
      return;
    }
    abandonment.cleanupStarted = true;
    queueMicrotask(() => {
      void this.performRequestCleanup(requestId, pending);
    });
  }

  private async performRequestCleanup(
    requestId: string,
    pending: Pending,
  ): Promise<void> {
    const abandonment = pending.abandonment;
    if (!abandonment || abandonment.cleanupFinished) return;
    const configured = this.timeoutMs > 0
      ? this.timeoutMs
      : REQUEST_CLEANUP_TIMEOUT_MS;
    const cleanupTimeoutMs = Math.min(
      Math.max(configured, 1),
      REQUEST_CLEANUP_TIMEOUT_MS,
    );
    const deadline = Date.now() + cleanupTimeoutMs;
    try {
      const result = await this.sendRequestNow(
        operations.requestCancel.name,
        { request_id: requestId },
        undefined,
        undefined,
        remainingTime(
          deadline,
          "request cancellation did not finish before the deadline",
        ),
      );
      const canceled = decodeRequestCancelResult(result);
      if (canceled) {
        if (abandonment.targetResponseObserved) {
          const responseError = await abandonment.targetResponse;
          if (responseError) throw responseError;
          throw new CmuxProtocolError(
            "request.cancel returned canceled true after the target responded",
          );
        }
        if (this.pending.get(requestId) === pending) {
          this.pending.delete(requestId);
        }
        this.releaseTerminalWait(requestId);
        abandonment.resolveTargetResponse(undefined);
      } else {
        const responseError = await waitUntilDeadline(
          abandonment.targetResponse,
          deadline,
          undefined,
          "request cancellation did not receive the completed target response",
        );
        if (responseError) throw responseError;
      }
    } catch (error) {
      const failure = error instanceof CmuxProtocolError
        ? error
        : new CmuxConnectionError(
          `request cancellation was not confirmed: ${String(error)}`,
        );
      if (!this.closed) this.fail(failure);
    } finally {
      if (this.pending.get(requestId) === pending) {
        this.pending.delete(requestId);
        this.finishPending(pending);
      }
      pending.reject(abandonment.originalError);
      this.finishRequestCleanup(pending);
    }
  }

  private finishRequestCleanup(pending: Pending): void {
    const abandonment = pending.abandonment;
    if (!abandonment || abandonment.cleanupFinished) return;
    abandonment.cleanupFinished = true;
    this.requestCleanups.delete(abandonment.cleanupBarrier);
    abandonment.resolveCleanupBarrier();
  }

  private finishPending(pending: Pending): void {
    if (pending.timer) clearTimeout(pending.timer);
    pending.removeAbort?.();
    pending.cancelUndispatched?.();
    pending.cancelUndispatched = undefined;
  }

  private reserveTerminalWait(requestId: string, timeoutMs: number): boolean {
    const now = Date.now();
    for (const [id, lease] of this.terminalWaitLeases) {
      if (lease.expiresAt !== undefined && lease.expiresAt <= now) {
        this.releaseTerminalWait(id);
      }
    }
    if (this.terminalWaitLeases.size >= TERMINAL_WAIT_CAPACITY) return false;
    this.terminalWaitLeases.set(requestId, {
      durationMs: timeoutMs + TERMINAL_WAIT_RELEASE_GRACE_MS,
    });
    return true;
  }

  private startTerminalWaitLease(requestId: string): void {
    const lease = this.terminalWaitLeases.get(requestId);
    if (!lease || lease.timer !== undefined) return;
    lease.expiresAt = Date.now() + lease.durationMs;
    lease.timer = setTimeout(
      () => this.releaseTerminalWait(requestId),
      lease.durationMs,
    );
  }

  private releaseTerminalWait(requestId: string): void {
    const lease = this.terminalWaitLeases.get(requestId);
    if (!lease) return;
    this.terminalWaitLeases.delete(requestId);
    if (lease.timer !== undefined) clearTimeout(lease.timer);
  }

  private fail(error: Error, attemptCleanup = true): void {
    if (this.closed) {
      if (!this.failureFinalized && !attemptCleanup) {
        this.failureAttemptCleanup = false;
      }
      return;
    }
    this.closed = true;
    this.failure = error;
    this.failureAttemptCleanup = attemptCleanup;
    this.failureStreams = [...this.streams.values()];
    if (this.activeTransportSends > 0) {
      if (!this.failureFinalizeScheduled) {
        this.failureFinalizeScheduled = true;
        queueMicrotask(() => this.finalizeFailure());
      }
      return;
    }
    this.finalizeFailure();
  }

  private finalizeFailure(): void {
    if (this.failureFinalized) return;
    this.failureFinalized = true;
    this.failureFinalizeScheduled = false;
    const error = this.failure ?? new CmuxConnectionError("resource client closed");
    const streams = this.failureStreams ?? [...this.streams.values()];
    this.failureStreams = undefined;
    try {
      for (const pending of this.pending.values()) {
        this.finishPending(pending);
        if (pending.abandonment) {
          if (!pending.abandonment.targetResponseObserved) {
            pending.abandonment.targetResponseObserved = true;
            pending.abandonment.resolveTargetResponse(error);
          }
          pending.reject(pending.abandonment.originalError);
        } else {
          pending.reject(error);
        }
      }
      this.pending.clear();
      for (const lease of this.terminalWaitLeases.values()) {
        if (lease.timer !== undefined) clearTimeout(lease.timer);
      }
      this.terminalWaitLeases.clear();
      for (const state of streams) {
        this.rejectStreamCancellation(state, error);
        this.finishStream(state, { streamId: state.id, reason: "error", error });
      }
      this.streams.clear();
      for (const unsubscribe of this.unsubscribers.splice(0)) {
        try {
          unsubscribe();
        } catch {
          // Continue cleanup so route cancellation and transport close still run.
        }
      }
      if (this.failureAttemptCleanup) {
        for (const state of streams) {
          if (
            state.openDispatched
            && !state.openAcknowledged
            && !state.openRejected
          ) {
            this.cancelStreamBestEffort(state);
          }
        }
      }
    } finally {
      this.closeTransportOnce();
    }
  }

  private closeTransportOnce(): void {
    if (this.transportCloseStarted) return;
    this.transportCloseStarted = true;
    try {
      this.transport.close();
    } catch {
      // Failure cleanup already preserved the original connection error.
    }
  }
}

function terminalWaitServerTimeout(
  operation: string,
  params: Readonly<Record<string, unknown>>,
  requestTimeoutMs: number,
): bigint | undefined {
  if (!isCancelableTerminalWait(operation)) return undefined;
  const requestBound = BigInt(Math.min(
    Math.floor(requestTimeoutMs > 0 ? requestTimeoutMs : DEFAULT_REQUEST_TIMEOUT_MS),
    MAX_TERMINAL_WAIT_TIMEOUT_MS,
  ));
  const supplied = params.timeout_ms;
  if (supplied === undefined) return requestBound;
  if (typeof supplied !== "string" || !/^(0|[1-9][0-9]{0,19})$/.test(supplied)) {
    return undefined;
  }
  const suppliedBound = BigInt(supplied);
  return suppliedBound < requestBound ? suppliedBound : requestBound;
}

function isCancelableTerminalWait(operation: string): boolean {
  return operation === "terminal.wait" || operation === "terminal.wait_exit";
}

function validateTimeout(timeoutMs: number): void {
  if (
    !Number.isFinite(timeoutMs)
    || timeoutMs < 0
    || timeoutMs > MAX_TIMEOUT_MS
  ) {
    throw new TypeError("timeoutMs must be between 0 and 2147483647");
  }
}

function remainingTime(deadline: number, message: string): number {
  const remaining = deadline - Date.now();
  if (remaining <= 0) throw new CmuxTimeoutError(message);
  return remaining;
}

function monotonicNow(): number {
  return performance.now();
}

export class ResourceStream<Value>
implements AsyncIterable<StreamItem<Value>>, AsyncIterator<StreamItem<Value>> {
  private canceling: Promise<void> | undefined;

  constructor(
    private readonly protocol: ResourceProtocol,
    private readonly state: StreamState<Value>,
  ) {}

  get id(): StreamId {
    return this.state.id;
  }

  /** Lease required to size or release a terminal/browser attachment. */
  get attachmentLease(): string | undefined {
    return this.state.attachmentLease;
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
    if (this.canceling) return this.canceling;
    if (this.state.end) return;
    if (signal?.aborted) throw abortError();
    this.canceling = this.protocol.cancelStream(this.id, signal);
    await this.canceling;
  }

  async return(): Promise<IteratorResult<StreamItem<Value>>> {
    await this.cancel();
    return { done: true, value: undefined };
  }

  setAbortCleanup(cleanup: () => void): void {
    if (this.state.end) cleanup();
    else this.state.abortCleanup = cleanup;
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

type DecodedResponse =
  | { readonly ok: true; readonly result: unknown }
  | { readonly ok: false; readonly error: ResourceError };

function decodeResponseEnvelope(value: Record<string, unknown>): DecodedResponse {
  if (
    value.protocol !== PROTOCOL
    || value.type !== "response"
    || typeof value.id !== "string"
    || typeof value.ok !== "boolean"
  ) {
    throw new CmuxProtocolError("invalid response envelope");
  }
  if (value.ok) {
    requireShape(
      value,
      ["protocol", "type", "id", "ok", "result"],
      ["protocol", "type", "id", "ok", "result"],
      "successful response",
    );
    return { ok: true, result: value.result };
  }
  requireShape(
    value,
    ["protocol", "type", "id", "ok", "error"],
    ["protocol", "type", "id", "ok", "error"],
    "failed response",
  );
  return { ok: false, error: decodeResourceError(value.error) };
}

function decodeStreamItemEnvelope<Value>(
  value: Record<string, unknown>,
  expectedId: StreamId,
  decode: (value: unknown) => Value,
  validate?: (value: Value, cursor: Cursor | undefined) => void,
): StreamItem<Value> {
  requireShape(
    value,
    ["protocol", "type", "stream_id", "sequence", "item"],
    ["protocol", "type", "stream_id", "sequence", "cursor", "item"],
    "stream item",
  );
  if (
    value.protocol !== PROTOCOL
    || value.type !== "stream_item"
    || value.stream_id !== expectedId
  ) {
    throw new CmuxProtocolError("invalid stream item envelope");
  }
  const cursor = Object.hasOwn(value, "cursor")
    ? decodeCursor(value.cursor)
    : undefined;
  const decoded = decode(value.item);
  validate?.(decoded, cursor);
  return Object.freeze({
    streamId: expectedId,
    sequence: decimalString(requireString(value.sequence, "sequence")),
    ...(cursor === undefined ? {} : { cursor }),
    value: decoded,
  });
}

function decodeStreamEndEnvelope(
  value: Record<string, unknown>,
  expectedId: StreamId,
): StreamEnd {
  requireShape(
    value,
    ["protocol", "type", "stream_id", "reason"],
    ["protocol", "type", "stream_id", "reason", "cursor", "error", "recovery"],
    "stream end",
  );
  if (
    value.protocol !== PROTOCOL
    || value.type !== "stream_end"
    || value.stream_id !== expectedId
  ) {
    throw new CmuxProtocolError("invalid stream end envelope");
  }
  const reason = requireString(value.reason, "stream end reason");
  if (!["completed", "canceled", "closed", "gap", "error"].includes(reason)) {
    throw new CmuxProtocolError("invalid stream end reason");
  }
  const hasError = Object.hasOwn(value, "error");
  if ((reason === "error") !== hasError) {
    throw new CmuxProtocolError(
      "stream end error must be present exactly when reason is error",
    );
  }
  const cursor = Object.hasOwn(value, "cursor")
    ? decodeCursor(value.cursor)
    : undefined;
  const error = hasError ? decodeResourceError(value.error) : undefined;
  const recovery = Object.hasOwn(value, "recovery")
    ? requireString(value.recovery, "stream end recovery")
    : undefined;
  return Object.freeze({
    streamId: expectedId,
    reason: reason as StreamEnd["reason"],
    ...(cursor ? { cursor } : {}),
    ...(error ? { error } : {}),
    ...(recovery !== undefined ? { recovery } : {}),
  });
}

function requireShape(
  value: Record<string, unknown>,
  required: readonly string[],
  allowed: readonly string[],
  context: string,
): void {
  const allowedFields = new Set(allowed);
  const unknown = Object.keys(value).find((field) => !allowedFields.has(field));
  if (unknown !== undefined) {
    throw new CmuxProtocolError(
      `${context} contains unknown field ${JSON.stringify(unknown)}`,
    );
  }
  const missing = required.find((field) => !Object.hasOwn(value, field));
  if (missing !== undefined) {
    throw new CmuxProtocolError(
      `${context} is missing field ${JSON.stringify(missing)}`,
    );
  }
}

function createStreamCancellationConfirmation(): StreamCancellationConfirmation {
  let resolve!: (end: StreamEnd) => void;
  let reject!: (error: unknown) => void;
  const promise = new Promise<StreamEnd>((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return {
    promise,
    resolve,
    reject,
    responseConfirmed: false,
    settled: false,
  };
}

function createRequestAbandonment(
  originalError: CmuxAbortError | CmuxTimeoutError,
): RequestAbandonment {
  let resolveTargetResponse!: (error: Error | undefined) => void;
  const targetResponse = new Promise<Error | undefined>((resolve) => {
    resolveTargetResponse = resolve;
  });
  let resolveCleanupBarrier!: () => void;
  const cleanupBarrier = new Promise<void>((resolve) => {
    resolveCleanupBarrier = resolve;
  });
  return {
    originalError,
    targetResponse,
    resolveTargetResponse,
    cleanupBarrier,
    resolveCleanupBarrier,
    targetResponseObserved: false,
    cleanupStarted: false,
    cleanupFinished: false,
  };
}

function waitUntilDeadline<Value>(
  promise: Promise<Value>,
  deadline: number | undefined,
  signal: AbortSignal | undefined,
  timeoutMessage: string,
): Promise<Value> {
  return new Promise<Value>((resolve, reject) => {
    let settled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const finish = (callback: () => void) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      callback();
    };
    const abort = () => finish(() => reject(abortError()));
    promise.then(
      (value) => finish(() => resolve(value)),
      (error) => finish(() => reject(error)),
    );
    if (signal?.aborted) {
      abort();
      return;
    }
    signal?.addEventListener("abort", abort, { once: true });
    if (deadline !== undefined) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        finish(() => reject(new CmuxTimeoutError(timeoutMessage)));
        return;
      }
      timer = setTimeout(
        () => finish(() => reject(new CmuxTimeoutError(timeoutMessage))),
        remaining,
      );
    }
  });
}

function decodeEmptyResult(value: unknown): void {
  if (!isRecord(value) || Object.keys(value).length !== 0) {
    throw new CmuxProtocolError("empty result must be an object with no fields");
  }
}

function decodeRequestCancelResult(value: unknown): boolean {
  if (
    !isRecord(value)
    || Object.keys(value).length !== 1
    || !Object.hasOwn(value, "canceled")
    || typeof value.canceled !== "boolean"
  ) {
    throw new CmuxProtocolError(
      "request.cancel result must contain exactly boolean canceled",
    );
  }
  return value.canceled;
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
  if (!hasUtf8ByteLength(generation, 1, 128)) {
    throw new CmuxProtocolError(
      "cursor.generation must contain 1 to 128 UTF-8 bytes",
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
    || Object.keys(value).length !== 4
    || !Object.hasOwn(value, "code")
    || !Object.hasOwn(value, "message")
    || !Object.hasOwn(value, "details")
    || !Object.hasOwn(value, "retryable")
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
      || !hasUtf8ByteLength(details.confirmation_token, 1, 128)
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
      || !isValidIdempotencyKey(details.idempotency_key)
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
