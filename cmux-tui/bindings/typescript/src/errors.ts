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

  constructor(message: string, commandId?: unknown, response?: unknown, errorCode?: string) {
    super(message);
    this.commandId = commandId;
    this.response = response;
    this.errorCode = errorCode;
  }
}

export class CmuxConnectionError extends CmuxError {}
export class CmuxProtocolError extends CmuxError {}
export class CmuxTimeoutError extends CmuxError {}
