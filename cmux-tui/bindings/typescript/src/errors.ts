import type { DecimalString, PaneId } from "./ids.js";

export class CmuxError extends Error {
  constructor(message: string) {
    super(message);
    this.name = new.target.name;
  }
}

/** Every structured protocol error field is retained. */
export class ResourceError<
  Code extends string = string,
  Details = unknown,
> extends CmuxError {
  readonly code: Code;
  readonly details: Details;
  readonly retryable: boolean;

  constructor(code: Code, message: string, details: Details, retryable: boolean) {
    super(message);
    this.code = code;
    this.details = details;
    this.retryable = retryable;
  }
}

export interface MutationIndeterminateDetails {
  readonly idempotency_key: string;
  readonly operation: string;
  readonly recovery: "inspect_state_then_retry_with_new_key";
}

export interface ConfirmationRequiredDetails {
  readonly confirmation_token: string;
  readonly revision: DecimalString;
  readonly closes_panes: readonly PaneId[];
}

export class ConfirmationRequiredError extends ResourceError<
  "confirmation.required",
  ConfirmationRequiredDetails
> {
  constructor(message: string, details: ConfirmationRequiredDetails) {
    super("confirmation.required", message, details, false);
  }
}

export class MutationIndeterminateError extends ResourceError<
  "mutation.indeterminate",
  MutationIndeterminateDetails
> {
  constructor(message: string, details: MutationIndeterminateDetails) {
    super("mutation.indeterminate", message, details, false);
  }
}

export class CmuxConnectionError extends CmuxError {}
/** The server rejected the WebSocket credential before routing requests. */
export class CmuxAuthenticationRejectedError extends CmuxConnectionError {}
export class CmuxProtocolError extends CmuxError {}
export class CmuxTimeoutError extends CmuxError {}
export class CmuxAbortError extends CmuxError {}

/**
 * A mutation may have reached the server, but its structured response was not
 * observed. Inspect state before retrying with a new idempotency key.
 */
export class MutationTransportUncertainError extends CmuxError {
  readonly operation: string;
  readonly idempotencyKey: string;
  readonly cause: Error;
  readonly recovery = "inspect_state_then_retry_with_new_key" as const;

  constructor(operation: string, idempotencyKey: string, cause: Error) {
    super(
      `${operation} transport failed before a response; outcome is uncertain`,
    );
    this.operation = operation;
    this.idempotencyKey = idempotencyKey;
    this.cause = cause;
  }
}

export class StreamError extends CmuxError {
  readonly reason: string;
  readonly error: ResourceError | undefined;
  readonly recovery: string | undefined;

  constructor(
    reason: string,
    options: { error?: ResourceError; recovery?: string } = {},
  ) {
    super(
      `stream ended: ${reason}`
        + (options.error ? `: ${options.error.message}` : "")
        + (options.recovery ? ` (${options.recovery})` : ""),
    );
    this.reason = reason;
    this.error = options.error;
    this.recovery = options.recovery;
  }
}
