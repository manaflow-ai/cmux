let convexAuthReadyPromiseResolveFn:
  | ((isAuthenticated: boolean) => void)
  | null = null;
export const convexAuthReadyPromise = new Promise<boolean>((resolve) => {
  convexAuthReadyPromiseResolveFn = resolve;
});

export function signalConvexAuthReady(isAuthenticated: boolean) {
  convexAuthReadyPromiseResolveFn?.(isAuthenticated);
}
