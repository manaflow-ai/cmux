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
  readonly delivery: CmuxErrorDelivery | undefined;

  constructor(
    message: string,
    commandId?: unknown,
    response?: unknown,
    delivery?: CmuxErrorDelivery,
  ) {
    super(message);
    this.commandId = commandId;
    this.response = response;
    this.delivery = delivery;
  }
}

export class CmuxConnectionError extends CmuxError {}
export class CmuxProtocolError extends CmuxError {}
export class CmuxTimeoutError extends CmuxError {}
