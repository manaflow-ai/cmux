import { AsyncLocalStorage } from "node:async_hooks";

export interface RequestContext {
  authToken?: string;
}

const storage = new AsyncLocalStorage<RequestContext>();

export function runWithAuthToken<T>(
  authToken: string | null | undefined,
  fn: () => T
): T {
  return storage.run({ authToken: authToken ?? undefined }, fn);
}

export function getAuthToken(): string | undefined {
  return storage.getStore()?.authToken;
}

export function getRequestContext(): RequestContext | undefined {
  return storage.getStore();
}

