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

export class MutationIndeterminateError extends ResourceError<
  "mutation.indeterminate",
  MutationIndeterminateDetails
> {
  constructor(message: string, details: MutationIndeterminateDetails) {
    super("mutation.indeterminate", message, details, false);
  }
}

export class CmuxConnectionError extends CmuxError {}
export class CmuxProtocolError extends CmuxError {}
export class CmuxTimeoutError extends CmuxError {}
export class CmuxAbortError extends CmuxError {}

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
