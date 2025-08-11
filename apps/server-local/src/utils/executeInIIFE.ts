import { serverLogger } from "./fileLogger.js";

export function executeInIIFE<T>(code: () => T | Promise<T>): void {
  try {
    // Execute the function in an IIFE
    (async () => {
      await code();
    })();
  } catch (error) {
    serverLogger.error("Error executing code:", error);
  }
}
