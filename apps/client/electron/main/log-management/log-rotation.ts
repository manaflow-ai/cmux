import { appendFileSync, existsSync, renameSync, statSync, unlinkSync } from "node:fs";

export interface LogRotationOptions {
  maxBytes: number;
  maxBackups: number;
}

function getFileSize(filePath: string): number {
  try {
    return statSync(filePath).size;
  } catch {
    return 0;
  }
}

function rotateLogFile(filePath: string, maxBackups: number): void {
  if (maxBackups <= 0) {
    try {
      if (existsSync(filePath)) {
        unlinkSync(filePath);
      }
    } catch {
      // ignore inability to delete log file
    }
    return;
  }

  for (let index = maxBackups; index >= 1; index -= 1) {
    const source = index === 1 ? filePath : `${filePath}.${index - 1}`;
    const destination = `${filePath}.${index}`;

    try {
      if (!existsSync(source)) {
        continue;
      }
      if (existsSync(destination)) {
        unlinkSync(destination);
      }
      renameSync(source, destination);
    } catch {
      // ignore rename/remove errors to avoid crashing the app
    }
  }
}

export function appendLogWithRotation(
  filePath: string,
  data: string,
  options: LogRotationOptions
): void {
  const incomingBytes = Buffer.byteLength(data, "utf8");
  if (incomingBytes <= 0) {
    return;
  }

  if (options.maxBytes > 0) {
    const currentSize = getFileSize(filePath);
    if (currentSize + incomingBytes > options.maxBytes) {
      rotateLogFile(filePath, options.maxBackups);
    }
  }

  try {
    appendFileSync(filePath, data, { encoding: "utf8" });
  } catch {
    // ignore write failures
  }
}
