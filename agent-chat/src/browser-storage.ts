type BrowserStorage = Pick<Storage, "getItem" | "setItem" | "removeItem">;

/** Storage failures must not interrupt a live session or discard its draft. */
export function createRecoverableStorage(resolve: () => BrowserStorage | undefined): BrowserStorage {
  const cached = new Map<string, string | null>();
  const pending = new Set<string>();
  return {
    getItem(key) {
      // A rejected write/remove is newer than the value still on disk. A null
      // tombstone also prevents a consumed draft from reappearing on remount.
      if (pending.has(key)) return cached.get(key) ?? null;
      try {
        const storage = resolve();
        if (storage) {
          const value = storage.getItem(key);
          cached.set(key, value);
          return value;
        }
      } catch {
        // Accessing the storage property itself can throw SecurityError.
      }
      return cached.get(key) ?? null;
    },
    setItem(key, value) {
      cached.set(key, value);
      pending.add(key);
      try {
        const storage = resolve();
        if (storage) {
          storage.setItem(key, value);
          pending.delete(key);
        }
      } catch {
        // Keep the selected value available to other views in this page.
      }
    },
    removeItem(key) {
      cached.set(key, null);
      pending.add(key);
      try {
        const storage = resolve();
        if (storage) {
          storage.removeItem(key);
          pending.delete(key);
        }
      } catch {
        // Keep the tombstone until a later successful mutation of this key.
      }
    },
  };
}

// Resolve lazily inside the guarded operations; evaluating a default argument
// such as `storage = localStorage` can throw before a function's try/catch.
export const preferenceStorage = createRecoverableStorage(() => globalThis.localStorage);
export const draftStorage = createRecoverableStorage(() => globalThis.sessionStorage);
