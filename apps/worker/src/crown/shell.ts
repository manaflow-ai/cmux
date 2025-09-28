import { Buffer } from "node:buffer";
import { exec as childExec } from "node:child_process";
import { promisify } from "node:util";

export type ExecError = Error & {
  stdout?: string | Buffer;
  stderr?: string | Buffer;
  code?: number | string;
  status?: number;
};

export const execAsync = promisify(childExec);
