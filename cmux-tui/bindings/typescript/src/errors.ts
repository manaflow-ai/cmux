import type { CmuxErrorDelivery } from "./protocol/common.js";

export class CmuxError extends Error {
  constructor(message: string) {
    super(message);
    this.name = new.target.name;
  }
}

export class CmuxCommandError extends CmuxError {
  readonly commandId: unknown;
  readonly response: unknown;
  readonly errorCode: string | undefined;
  readonly delivery: CmuxErrorDelivery | undefined;

  constructor(
    message: string,
    commandId?: unknown,
    response?: unknown,
    delivery?: CmuxErrorDelivery,
  );
  constructor(
    message: string,
    commandId?: unknown,
    response?: unknown,
    errorCode?: string,
    delivery?: CmuxErrorDelivery,
  );
  constructor(
    message: string,
    commandId?: unknown,
    response?: unknown,
    errorCode?: string,
    delivery?: CmuxErrorDelivery,
  ) {
    super(message);
    this.commandId = commandId;
    this.response = response;
    const legacyDelivery = delivery === undefined
      && (errorCode === "known-not-delivered" || errorCode === "ambiguous")
      ? errorCode
      : undefined;
    this.errorCode = legacyDelivery === undefined ? errorCode : undefined;
    this.delivery = delivery ?? legacyDelivery;
  }
}

export class CmuxConnectionError extends CmuxError {}
export class CmuxProtocolError extends CmuxError {}
export class CmuxTimeoutError extends CmuxError {}
