export class CmuxError extends Error {
  constructor(message: string) {
    super(message);
    this.name = new.target.name;
  }
}

export class CmuxCommandError extends CmuxError {
  readonly commandId: unknown;
  readonly response: unknown;

  constructor(message: string, commandId?: unknown, response?: unknown) {
    super(message);
    this.commandId = commandId;
    this.response = response;
  }
}

export class CmuxConnectionError extends CmuxError {}
export class CmuxProtocolError extends CmuxError {}
export class CmuxTimeoutError extends CmuxError {}
