import type { CmuxCommand } from "./generated/commands.js";
import type { CmuxAuthority } from "./generated/metadata.js";

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
/** The server rejected the WebSocket credential before routing requests. */
export class CmuxAuthenticationRejectedError extends CmuxConnectionError {}
export class CmuxProtocolError extends CmuxError {}
export class CmuxTimeoutError extends CmuxError {}
export class CmuxAbortError extends CmuxError {}

/** A command was blocked locally because its authority was not enabled. */
export class CmuxAuthorityError extends CmuxError {
  readonly command: CmuxCommand;
  readonly requiredAuthority: CmuxAuthority;
  readonly grantedAuthorities: readonly CmuxAuthority[];

  constructor(
    command: CmuxCommand,
    requiredAuthority: CmuxAuthority,
    grantedAuthorities: readonly CmuxAuthority[],
  ) {
    super(`${command} requires ${requiredAuthority} authority`);
    this.command = command;
    this.requiredAuthority = requiredAuthority;
    this.grantedAuthorities = Object.freeze([...grantedAuthorities]);
  }
}
